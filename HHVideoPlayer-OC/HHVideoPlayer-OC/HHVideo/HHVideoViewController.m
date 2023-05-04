//
//  HHVideoViewController.m
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import "HHVideoViewController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import "HHVideoDecoder.h"
#import "HHAudioManager.h"
#import "HHVideoGLView.h"

#import "HHPlayerManager.h"


#define LOCAL_MIN_BUFFERED_DURATION   0.2
#define LOCAL_MAX_BUFFERED_DURATION   0.4
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0

@interface HHVideoViewController () {
//    HHVideoDecoder *_decoder;
//    dispatch_queue_t    _dispatchQueue;
//    NSMutableArray *_videoFrames;
//    NSMutableArray *_audioFrames;
//    NSDate *_currentAudioFrame;
//    NSInteger _currentAudioFramePos;
//    CGFloat _moviePosition;
//    BOOL    _disableUpdateHUB;
//    BOOL    _fullscreen;
//    BOOL    _hiddenHUD;
//    BOOL    _interrupted;
//
//    HHVideoGLView *_glView;
//
//
//
//    CGFloat _minBufferedDuration;
//    CGFloat _maxBufferedDuration;
}

@end

@implementation HHVideoViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    UIView *aView = [[UIView alloc] initWithFrame:CGRectMake(0, 100, self.view.frame.size.width, 250)];
    [self.view addSubview:aView];
    self.view.backgroundColor = [UIColor whiteColor];
     
    NSString *path = [[NSBundle mainBundle] pathForResource:@"MyHeartWillGoOn" ofType:@"mp4"];
    [[HHPlayerManager sharedInstance] playerManagerWithContentPath:path targetView:aView];
      
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.view addSubview:btn];
    [btn addTarget:self action:@selector(reponsePlay) forControlEvents:UIControlEventTouchUpInside];
    btn.backgroundColor = [UIColor redColor];
    [btn setTitle:@"播放" forState:UIControlStateNormal];
    btn.frame = CGRectMake(0, 350, 100, 50);
    
    UIButton *btnPause = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.view addSubview:btnPause];
    [btnPause addTarget:self action:@selector(reponsePause) forControlEvents:UIControlEventTouchUpInside];
    btnPause.backgroundColor = [UIColor grayColor];
    [btnPause setTitle:@"暂停" forState:UIControlStateNormal];
    btnPause.frame = CGRectMake(150, 350, 100, 50);
}

- (void)reponsePlay {
    [[HHPlayerManager sharedInstance] play];
}

- (void)reponsePause {
    [[HHPlayerManager sharedInstance] pause];
}
@end
