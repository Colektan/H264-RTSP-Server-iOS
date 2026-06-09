//
//  AVEncoder.mm
//  Encoder Demo
//
//  Created by Geraint Davies on 14/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "AVEncoder.h"
#import <VideoToolbox/VideoToolbox.h>

@interface AVEncoder () {
    int _width;
    int _height;
    VTCompressionSessionRef _compressionSession;
    
    encoder_handler_t _outputBlock;
    param_handler_t _paramsBlock;
    
    BOOL _hasSentParams;
    int _bitspersecond;
    int _frameCount;
    double _firstpts;
    
    NSData* _avcC;
    double _lastBitrateCalcTime;
    int _bytesSinceLastBitrateCalc;
}

- (BOOL)createCompressionSession;
- (void)handleEncodedFrame:(CMSampleBufferRef)sampleBuffer;

@end

// VTCompressionSession callback
static void compressionOutputCallback(
    void *CM_NULLABLE outputCallbackRefCon,
    void *CM_NULLABLE sourceFrameRefCon,
    OSStatus status,
    VTEncodeInfoFlags infoFlags,
    CM_NULLABLE CMSampleBufferRef sampleBuffer
) {
    if (status != noErr || !sampleBuffer) {
        NSLog(@"[AVEncoder] VideoToolbox callback error: %d", (int)status);
        return;
    }
    
    AVEncoder *encoder = (__bridge AVEncoder *)outputCallbackRefCon;
    [encoder handleEncodedFrame:sampleBuffer];
}

@implementation AVEncoder

@synthesize bitspersecond = _bitspersecond;

+ (AVEncoder*) encoderForHeight:(int) height andWidth:(int) width
{
    AVEncoder* enc = [AVEncoder alloc];
    [enc initForHeight:height andWidth:width];
    return enc;
}

- (void) initForHeight:(int)height andWidth:(int)width
{
    _height = height;
    _width = width;
    _compressionSession = NULL;
    _hasSentParams = NO;
    _bitspersecond = 0;
    _frameCount = 0;
    _firstpts = -1;
    _lastBitrateCalcTime = 0.0;
    _bytesSinceLastBitrateCalc = 0;
}

- (void) encodeWithBlock:(encoder_handler_t) block onParams: (param_handler_t) paramsHandler
{
    _outputBlock = block;
    _paramsBlock = paramsHandler;
    _hasSentParams = NO;
    _firstpts = -1;
    _bitspersecond = 0;
}

- (BOOL)createCompressionSession {
    OSStatus status = VTCompressionSessionCreate(
        NULL,
        _width,
        _height,
        kCMVideoCodecType_H264,
        NULL,
        NULL,
        NULL,
        compressionOutputCallback,
        (__bridge void *)(self),
        &_compressionSession
    );
    
    if (status != noErr) {
        NSLog(@"[AVEncoder] FAILED to create VTCompressionSession: %d", (int)status);
        return NO;
    }
    
    // Configure settings for real-time low-latency encoding
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_3_1);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    
    // Set 1.5 Mbps dynamic average bitrate
    int averageBitrate = 1500000;
    CFNumberRef avgBitrateRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &averageBitrate);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, avgBitrateRef);
    CFRelease(avgBitrateRef);
    
    // Set GOP Keyframe interval to 30 frames (1s GOP at 30 FPS)
    int maxKeyFrameInterval = 30;
    CFNumberRef gopRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &maxKeyFrameInterval);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, gopRef);
    CFRelease(gopRef);
    
    // Prepare session to begin encoding frames
    VTCompressionSessionPrepareToEncodeFrames(_compressionSession);
    
    NSLog(@"[AVEncoder] In-memory VideoToolbox session initialized successfully (%dx%d, Baseline 3.1, 1.5 Mbps, GOP 30)", _width, _height);
    return YES;
}

- (void) encodeFrame:(CMSampleBufferRef) sampleBuffer
{
    if (!_compressionSession) {
        if (![self createCompressionSession]) {
            return;
        }
    }
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        return;
    }
    
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    
    VTEncodeInfoFlags flags;
    OSStatus status = VTCompressionSessionEncodeFrame(
        _compressionSession,
        imageBuffer,
        pts,
        duration,
        NULL,
        NULL,
        &flags
    );
    
    if (status != noErr) {
        NSLog(@"[AVEncoder] VTCompressionSessionEncodeFrame failed: %d", (int)status);
    }
}

- (void)handleEncodedFrame:(CMSampleBufferRef)sampleBuffer {
    // 1. Extract SPS/PPS and construct avcC record on first keyframe
    if (!_hasSentParams) {
        CMVideoFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (formatDesc) {
            size_t spsSize = 0, ppsSize = 0;
            size_t paramCount = 0;
            const uint8_t *sps = NULL, *pps = NULL;
            
            OSStatus statusSPS = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, 0, &sps, &spsSize, &paramCount, NULL
            );
            OSStatus statusPPS = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc, 1, &pps, &ppsSize, &paramCount, NULL
            );
            
            if (statusSPS == noErr && statusPPS == noErr && sps && pps) {
                // Construct standard avcC block
                NSMutableData *avcC = [NSMutableData data];
                uint8_t version = 1;
                uint8_t profile = sps[1];
                uint8_t profile_compat = sps[2];
                uint8_t level = sps[3];
                uint8_t length_size = 0xFF; // lengthSizeMinusOne = 3 (4-byte length prefix)
                uint8_t num_sps = 0xE1; // numOfSequenceParameterSets = 1
                
                [avcC appendBytes:&version length:1];
                [avcC appendBytes:&profile length:1];
                [avcC appendBytes:&profile_compat length:1];
                [avcC appendBytes:&level length:1];
                [avcC appendBytes:&length_size length:1];
                [avcC appendBytes:&num_sps length:1];
                
                uint16_t spsLenBE = CFSwapInt16HostToBig((uint16_t)spsSize);
                [avcC appendBytes:&spsLenBE length:2];
                [avcC appendBytes:sps length:spsSize];
                
                uint8_t num_pps = 1;
                [avcC appendBytes:&num_pps length:1];
                uint16_t ppsLenBE = CFSwapInt16HostToBig((uint16_t)ppsSize);
                [avcC appendBytes:&ppsLenBE length:2];
                [avcC appendBytes:pps length:ppsSize];
                
                _avcC = [avcC copy];
                _hasSentParams = YES;
                NSLog(@"[AVEncoder] Parameter sets extracted. SPS size: %zu, PPS size: %zu. Triggering onParams...", spsSize, ppsSize);
                
                if (_paramsBlock) {
                    _paramsBlock(_avcC);
                }
            }
        }
    }
    
    // 2. Extract H.264 NAL units from the CMBlockBuffer
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        return;
    }
    
    size_t totalLength = 0;
    char *dataPointer = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
    if (status == noErr && dataPointer) {
        size_t bufferOffset = 0;
        NSMutableArray *nalus = [NSMutableArray array];
        
        while (bufferOffset < totalLength - 4) {
            uint32_t naluLength = 0;
            memcpy(&naluLength, dataPointer + bufferOffset, 4);
            naluLength = CFSwapInt32BigToHost(naluLength);
            
            if (bufferOffset + 4 + naluLength > totalLength) {
                break;
            }
            
            NSData *naluData = [NSData dataWithBytes:(dataPointer + bufferOffset + 4) length:naluLength];
            [nalus addObject:naluData];
            
            bufferOffset += 4 + naluLength;
        }
        
        // Compute frame presentation timestamp (PTS) in seconds
        CMTime ptsTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        double pts = (double)ptsTime.value / ptsTime.timescale;
        
        // Track bitrate stats
        _bytesSinceLastBitrateCalc += (int)totalLength;
        double currentUptime = [[NSProcessInfo processInfo] systemUptime];
        if (_lastBitrateCalcTime <= 0) {
            _lastBitrateCalcTime = currentUptime;
        }
        if (currentUptime - _lastBitrateCalcTime >= 1.0) {
            _bitspersecond = (int)(_bytesSinceLastBitrateCalc * 8 / (currentUptime - _lastBitrateCalcTime));
            _bytesSinceLastBitrateCalc = 0;
            _lastBitrateCalcTime = currentUptime;
        }
        
        // Broadcast the frame NALUs via output callback
        if (_outputBlock && nalus.count > 0) {
            _outputBlock(nalus, pts);
        }
    }
}

- (NSData*) getConfigData
{
    return [_avcC copy];
}

- (void) shutdown
{
    if (_compressionSession) {
        VTCompressionSessionInvalidate(_compressionSession);
        CFRelease(_compressionSession);
        _compressionSession = NULL;
        NSLog(@"[AVEncoder] VideoToolbox session invalidated and shut down.");
    }
    _avcC = nil;
}

- (void)dealloc {
    [self shutdown];
}

@end
