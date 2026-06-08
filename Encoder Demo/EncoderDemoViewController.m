//
//  EncoderDemoViewController.m
//  Encoder Demo
//
//  Created by Geraint Davies on 11/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

#import "EncoderDemoViewController.h"
#import "CameraServer.h"

@implementation EncoderDemoViewController

@synthesize cameraView;
@synthesize serverAddress;

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self startPreview];
    [self setupCameraDropdown];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    CGSize size = self.view.bounds.size;
    
    // 1. Update camera preview container frame
    self.cameraView.frame = self.view.bounds;
    
    AVCaptureVideoPreviewLayer* preview = [[CameraServer server] getPreviewLayer];
    if (preview) {
        preview.frame = self.cameraView.bounds;
    }
    
    // 2. Query safe area
    UIEdgeInsets safeArea = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safeArea = self.view.safeAreaInsets;
    }
    
    // 3. Layout the camera menu button at top-left
    if (self.cameraMenuButton) {
        CGFloat topPadding = safeArea.top > 0 ? safeArea.top : 20;
        CGFloat leftPadding = safeArea.left > 0 ? safeArea.left : 20;
        self.cameraMenuButton.frame = CGRectMake(leftPadding, topPadding + 10, 150, 36);
    }
    
    // 4. Layout the server address label at bottom-center
    if (self.serverAddress) {
        CGFloat labelWidth = 320;
        CGFloat labelHeight = 36;
        CGFloat bottomPadding = safeArea.bottom > 0 ? safeArea.bottom : 20;
        self.serverAddress.frame = CGRectMake((size.width - labelWidth) / 2.0, size.height - bottomPadding - 40, labelWidth, labelHeight);
        
        // Style the label to look premium
        self.serverAddress.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.6];
        self.serverAddress.textColor = [UIColor whiteColor];
        self.serverAddress.layer.cornerRadius = 8;
        self.serverAddress.clipsToBounds = YES;
        self.serverAddress.textAlignment = NSTextAlignmentCenter;
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        AVCaptureVideoPreviewLayer* preview = [[CameraServer server] getPreviewLayer];
        if (preview) {
            UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationPortrait;
            if (@available(iOS 13.0, *)) {
                interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            } else {
                interfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
            }
            
            AVCaptureVideoOrientation videoOrientation;
            switch (interfaceOrientation) {
                case UIInterfaceOrientationPortrait:
                    videoOrientation = AVCaptureVideoOrientationPortrait;
                    break;
                case UIInterfaceOrientationPortraitUpsideDown:
                    videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
                    break;
                case UIInterfaceOrientationLandscapeLeft:
                    videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
                    break;
                case UIInterfaceOrientationLandscapeRight:
                    videoOrientation = AVCaptureVideoOrientationLandscapeRight;
                    break;
                default:
                    videoOrientation = AVCaptureVideoOrientationPortrait;
                    break;
            }
            [[preview connection] setVideoOrientation:videoOrientation];
            [[CameraServer server] setVideoOutputOrientation:videoOrientation];
        }
    } completion:nil];
}

- (void) startPreview
{
    AVCaptureVideoPreviewLayer* preview = [[CameraServer server] getPreviewLayer];
    [preview removeFromSuperlayer];
    preview.frame = self.cameraView.bounds;
    
    // Set initial video orientation
    UIInterfaceOrientation interfaceOrientation = UIInterfaceOrientationPortrait;
    if (@available(iOS 13.0, *)) {
        // Safe check in case window is not yet loaded
        if (self.view.window.windowScene) {
            interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
        }
    } else {
        interfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
    }
    
    AVCaptureVideoOrientation videoOrientation;
    switch (interfaceOrientation) {
        case UIInterfaceOrientationPortrait:
            videoOrientation = AVCaptureVideoOrientationPortrait;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
            break;
        case UIInterfaceOrientationLandscapeRight:
            videoOrientation = AVCaptureVideoOrientationLandscapeRight;
            break;
        default:
            videoOrientation = AVCaptureVideoOrientationPortrait;
            break;
    }
    [[preview connection] setVideoOrientation:videoOrientation];
    [[CameraServer server] setVideoOutputOrientation:videoOrientation];
    
    [self.cameraView.layer addSublayer:preview];
    
    self.serverAddress.text = [[CameraServer server] getURL];
}

- (void)setupCameraDropdown {
    NSArray *cameras = [[CameraServer server] getAvailableRearCameras];
    if (cameras.count <= 1) {
        return;
    }
    
    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [menuButton setTitle:@"切换镜头 ▾" forState:UIControlStateNormal];
    menuButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    menuButton.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.6];
    [menuButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    menuButton.layer.cornerRadius = 8;
    menuButton.clipsToBounds = YES;
    
    [menuButton addTarget:self action:@selector(showCameraPicker:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:menuButton];
    self.cameraMenuButton = menuButton;
}

- (void)showCameraPicker:(UIButton *)sender {
    NSArray *cameras = [[CameraServer server] getAvailableRearCameras];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择摄像头" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSDictionary *camInfo in cameras) {
        NSString *name = camInfo[@"name"];
        AVCaptureDevice *device = camInfo[@"device"];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[CameraServer server] switchToDevice:device];
            NSLog(@"[EncoderDemo] Switched to camera: %@", name);
        }];
        [alert addAction:action];
    }
    
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancel];
    
    // For iPad popover compatibility
    alert.popoverPresentationController.sourceView = sender;
    alert.popoverPresentationController.sourceRect = sender.bounds;
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}
@end
