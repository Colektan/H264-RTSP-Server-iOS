//
//  CameraServer.m
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "CameraServer.h"
#import <H264_RTSP_Server_iOS/H264_RTSP_Server_iOS.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <CoreMedia/CoreMedia.h>

static CameraServer *theServer;

@interface CameraServer () <AVCaptureVideoDataOutputSampleBufferDelegate> {
  AVCaptureSession *_session;
  AVCaptureVideoPreviewLayer *_preview;
  AVCaptureVideoDataOutput *_output;
  dispatch_queue_t _captureQueue;

  AVEncoder *_encoder;

  RTSPServer *_rtsp;
  NSNetServiceBrowser *_localNetworkTriggerBrowser;
  int _tcpServerFd;
  NSMutableArray *_clientSockets;
  dispatch_queue_t _tcpServerQueue;
}
@end

@implementation CameraServer

+ (void)initialize {
  // test recommended to avoid duplicate init via subclass
  if (self == [CameraServer class]) {
    theServer = [[CameraServer alloc] init];
  }
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _tcpServerFd = -1;
  }
  return self;
}

+ (CameraServer *)server {
  // Trigger dummy UDP packet to trigger local network permission dialog on
  // modern iOS
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd >= 0) {
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(12345);
    dst.sin_addr.s_addr = inet_addr("224.0.0.251"); // mDNS multicast
    char dummy = 0;
    sendto(fd, &dummy, 1, 0, (struct sockaddr *)&dst, sizeof(dst));
    close(fd);
  }
  return theServer;
}

- (void)startup {
  if (_session == nil) {
    NSLog(@"Starting up server");

    // Start camera intrinsics TCP server
    _clientSockets = [NSMutableArray array];
    _tcpServerQueue = dispatch_queue_create("uk.co.gdcl.avencoder.tcpserver", DISPATCH_QUEUE_SERIAL);
    [self startTcpServer];

    // Trigger iOS 14+ local network permission prompt via Bonjour
    _localNetworkTriggerBrowser = [[NSNetServiceBrowser alloc] init];
    [_localNetworkTriggerBrowser searchForServicesOfType:@"_rtsp._tcp"
                                                inDomain:@"local."];

    // create capture device with video input
    _session = [[AVCaptureSession alloc] init];
    AVCaptureDevice *dev =
        [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *frameRateError = nil;
    if ([dev lockForConfiguration:&frameRateError]) {
      CMTime frameDuration;
      frameDuration.value = 1;
      frameDuration.timescale = 30;
      frameDuration.flags = kCMTimeFlags_Valid;
      frameDuration.epoch = 0;
      dev.activeVideoMinFrameDuration = frameDuration;
      dev.activeVideoMaxFrameDuration = frameDuration;
      [dev unlockForConfiguration];
      NSLog(@"[CameraServer] Camera frame rate successfully locked to 30 FPS.");
    } else {
      NSLog(@"[CameraServer] Failed to lock frame rate to 30 FPS: %@",
            frameRateError.localizedDescription);
    }
    AVCaptureDeviceInput *input =
        [AVCaptureDeviceInput deviceInputWithDevice:dev error:nil];
    [_session addInput:input];  

    // create an output for YUV output with self as delegate
    _captureQueue = dispatch_queue_create("uk.co.gdcl.avencoder.capture",
                                          DISPATCH_QUEUE_SERIAL);
    _output = [[AVCaptureVideoDataOutput alloc] init];
    [_output setSampleBufferDelegate:self queue:_captureQueue];
    NSDictionary *setcapSettings = [NSDictionary
        dictionaryWithObjectsAndKeys:
            [NSNumber
                numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
            kCVPixelBufferPixelFormatTypeKey, nil];
    _output.videoSettings = setcapSettings;
    [_session addOutput:_output];

    // Enable Camera Intrinsic Matrix Delivery on iOS 11+
    if (@available(iOS 11.0, *)) {
      AVCaptureConnection *connection = [_output connectionWithMediaType:AVMediaTypeVideo];
      if (connection && connection.cameraIntrinsicMatrixDeliverySupported) {
        connection.cameraIntrinsicMatrixDeliveryEnabled = YES;
        NSLog(@"[CameraServer] Camera intrinsic matrix delivery enabled!");
      } else {
        NSLog(@"[CameraServer] Camera intrinsic matrix delivery is NOT supported on this device.");
      }
    }

    // create an encoder
    _encoder = [AVEncoder encoderForHeight:480 andWidth:720];
    [_encoder
        encodeWithBlock:^int(NSArray *data, double pts) {
          if (_rtsp != nil) {
            _rtsp.bitrate = _encoder.bitspersecond;
            [_rtsp onVideoData:data time:pts];
          }
          return 0;
        }
        onParams:^int(NSData *data) {
          NSLog(@"[CameraServer] Received SPS/PPS parameters from encoder. "
                @"Starting RTSP listener...");
          _rtsp = [RTSPServer setupListener:data];
          if (_rtsp) {
            NSLog(@"[CameraServer] RTSP listener successfully started on port "
                  @"8554!");

            // Self-connectivity test
            dispatch_async(
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                ^{
                  int test_fd = socket(AF_INET, SOCK_STREAM, 0);
                  if (test_fd >= 0) {
                    struct sockaddr_in test_addr;
                    memset(&test_addr, 0, sizeof(test_addr));
                    test_addr.sin_len = sizeof(test_addr);
                    test_addr.sin_family = AF_INET;
                    test_addr.sin_port = htons(8554);
                    test_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
                    NSLog(@"[CameraServer] Running self-connectivity test to "
                          @"127.0.0.1:8554...");
                    int res = connect(test_fd, (struct sockaddr *)&test_addr,
                                      sizeof(test_addr));
                    if (res == 0) {
                      NSLog(@"[CameraServer] Self-connectivity test SUCCESS! "
                            @"Server is actively accepting connections on port "
                            @"8554.");
                    } else {
                      NSLog(@"[CameraServer] Self-connectivity test FAILED! "
                            @"errno = %d",
                            errno);
                    }
                    close(test_fd);
                  }
                });

          } else {
            NSLog(@"[CameraServer] FAILED to start RTSP listener!");
          }
          return 0;
        }];

    // start capture and a preview layer
    [_session startRunning];

    _preview = [AVCaptureVideoPreviewLayer layerWithSession:_session];
    _preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
  }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  
  if (@available(iOS 11.0, *)) {
    CFDataRef intrinsicData = CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, NULL);
    if (intrinsicData) {
      CFIndex len = CFDataGetLength(intrinsicData);
      const float *matrix = (const float *)CFDataGetBytePtr(intrinsicData);
      float fx = 0, fy = 0, cx = 0, cy = 0;
      if (len >= 48) {
        // SIMD 16-byte alignment per column (4 floats per column)
        fx = matrix[0];
        fy = matrix[5];
        cx = matrix[8];
        cy = matrix[9];
      } else if (len >= 36) {
        // Packed floats (3 floats per column)
        fx = matrix[0];
        fy = matrix[4];
        cx = matrix[6];
        cy = matrix[7];
      }
      
      CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
      int w = 0, h = 0;
      if (imageBuffer) {
        w = (int)CVPixelBufferGetWidth(imageBuffer);
        h = (int)CVPixelBufferGetHeight(imageBuffer);
      }
      
      [self sendIntrinsicsToClientsFx:fx fy:fy cx:cx cy:cy width:w height:h];
    }
  }

  // pass frame to encoder
  [_encoder encodeFrame:sampleBuffer];
}

- (void)shutdown {
  NSLog(@"shutting down server");
  if (_session) {
    [_session stopRunning];
    _session = nil;
  }
  if (_rtsp) {
    [_rtsp shutdownServer];
  }
  if (_encoder) {
    [_encoder shutdown];
  }
  if (_tcpServerFd >= 0) {
    int fd_to_close = _tcpServerFd;
    _tcpServerFd = -1;
    close(fd_to_close);
  }
  @synchronized(_clientSockets) {
    for (NSNumber *socketNum in _clientSockets) {
      close([socketNum intValue]);
    }
    [_clientSockets removeAllObjects];
  }
}

- (NSString *)getURL {
  NSString *ipaddr = [RTSPServer getIPAddress];
  NSString *url = [NSString stringWithFormat:@"rtsp://%@:8554/", ipaddr];
  return url;
}

- (AVCaptureVideoPreviewLayer *)getPreviewLayer {
  return _preview;
}

- (NSArray<NSDictionary *> *)getAvailableRearCameras {
  NSMutableArray *cameraList = [NSMutableArray array];

  // Define the physical rear camera types we want to query
  NSArray *deviceTypes = @[
    AVCaptureDeviceTypeBuiltInWideAngleCamera,
    AVCaptureDeviceTypeBuiltInUltraWideCamera,
    AVCaptureDeviceTypeBuiltInTelephotoCamera
  ];

  AVCaptureDeviceDiscoverySession *discoverySession =
      [AVCaptureDeviceDiscoverySession
          discoverySessionWithDeviceTypes:deviceTypes
                                mediaType:AVMediaTypeVideo
                                 position:AVCaptureDevicePositionBack];

  for (AVCaptureDevice *device in discoverySession.devices) {
    NSString *displayName = @"后置主摄像头";
    if ([device.deviceType
            isEqualToString:AVCaptureDeviceTypeBuiltInUltraWideCamera]) {
      displayName = @"后置超广角 (0.5x)";
    } else if ([device.deviceType
                   isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera]) {
      displayName = @"后置长焦";
    }
    [cameraList addObject:@{@"name" : displayName, @"device" : device}];
  }
  return cameraList;
}

- (void)switchToDevice:(AVCaptureDevice *)newDevice {
  if (!newDevice || !_session)
    return;

  [_session beginConfiguration];

  // Remove all current capture inputs
  for (AVCaptureInput *input in [_session.inputs copy]) {
    [_session removeInput:input];
  }

  // Add new device input
  NSError *error = nil;
  AVCaptureDeviceInput *newInput =
      [AVCaptureDeviceInput deviceInputWithDevice:newDevice error:&error];
  if (newInput && [_session canAddInput:newInput]) {
    [_session addInput:newInput];

    // Re-lock framerate configuration at 30 FPS on the new device
    NSError *frameRateError = nil;
    if ([newDevice lockForConfiguration:&frameRateError]) {
      CMTime frameDuration;
      frameDuration.value = 1;
      frameDuration.timescale = 30;
      frameDuration.flags = kCMTimeFlags_Valid;
      frameDuration.epoch = 0;
      newDevice.activeVideoMinFrameDuration = frameDuration;
      newDevice.activeVideoMaxFrameDuration = frameDuration;
      [newDevice unlockForConfiguration];
      NSLog(@"[CameraServer] Camera frame rate successfully locked to 30 FPS "
            @"on new device.");
    } else {
      NSLog(@"[CameraServer] Failed to lock frame rate on new device: %@",
            frameRateError.localizedDescription);
    }
  } else {
    NSLog(@"[CameraServer] Failed to add new input device: %@",
          error.localizedDescription);
  }

  [_session commitConfiguration];

  // Re-enable Camera Intrinsic Matrix Delivery on the new connection on iOS 11+
  if (@available(iOS 11.0, *)) {
    AVCaptureConnection *connection = [_output connectionWithMediaType:AVMediaTypeVideo];
    if (connection && connection.cameraIntrinsicMatrixDeliverySupported) {
      connection.cameraIntrinsicMatrixDeliveryEnabled = YES;
      NSLog(@"[CameraServer] Camera intrinsic matrix delivery enabled on new connection.");
    } else {
      NSLog(@"[CameraServer] Camera intrinsic matrix delivery is NOT supported on new connection.");
    }
  }
}

- (void)setVideoOutputOrientation:(AVCaptureVideoOrientation)orientation {
  if (!_output)
    return;
  AVCaptureConnection *videoConnection =
      [_output connectionWithMediaType:AVMediaTypeVideo];
  if (videoConnection && videoConnection.supportsVideoOrientation) {
    videoConnection.videoOrientation = orientation;
    NSLog(@"[CameraServer] Video output connection orientation successfully "
          @"updated to: %ld",
          (long)orientation);
  }
}

- (void)startTcpServer {
  dispatch_async(_tcpServerQueue, ^{
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
      NSLog(@"[CameraServer] Failed to create TCP socket for intrinsics.");
      return;
    }
    
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(8555); // Port 8555 for camera intrinsics
    addr.sin_addr.s_addr = INADDR_ANY;
    
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
      NSLog(@"[CameraServer] Failed to bind TCP socket for intrinsics.");
      close(server_fd);
      return;
    }
    
    if (listen(server_fd, 5) < 0) {
      NSLog(@"[CameraServer] Failed to listen on TCP socket for intrinsics.");
      close(server_fd);
      return;
    }
    
    self->_tcpServerFd = server_fd;
    NSLog(@"[CameraServer] Camera intrinsics TCP server started on port 8555!");
    
    while (self->_tcpServerFd >= 0) {
      struct sockaddr_in client_addr;
      socklen_t client_len = sizeof(client_addr);
      int client_fd = accept(self->_tcpServerFd, (struct sockaddr *)&client_addr, &client_len);
      if (client_fd >= 0) {
        int opt_nosigpipe = 1;
        setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &opt_nosigpipe, sizeof(opt_nosigpipe));
        
        @synchronized(self->_clientSockets) {
          [self->_clientSockets addObject:@(client_fd)];
          NSLog(@"[CameraServer] Intrinsics client connected! Total clients: %lu", (unsigned long)self->_clientSockets.count);
        }
      }
    }
  });
}

- (void)sendIntrinsicsToClientsFx:(float)fx fy:(float)fy cx:(float)cx cy:(float)cy width:(int)w height:(int)h {
  NSString *jsonStr = [NSString stringWithFormat:@"{\"fx\":%.4f,\"fy\":%.4f,\"cx\":%.4f,\"cy\":%.4f,\"w\":%d,\"h\":%d}\n", fx, fy, cx, cy, w, h];
  NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
  
  @synchronized(_clientSockets) {
    NSMutableArray *disconnected = [NSMutableArray array];
    for (NSNumber *socketNum in _clientSockets) {
      int fd = [socketNum intValue];
      ssize_t sent = send(fd, data.bytes, data.length, 0);
      if (sent < 0) {
        [disconnected addObject:socketNum];
        close(fd);
      }
    }
    if (disconnected.count > 0) {
      [_clientSockets removeObjectsInArray:disconnected];
      NSLog(@"[CameraServer] Removed %lu disconnected intrinsics clients.", (unsigned long)disconnected.count);
    }
  }
}

@end
