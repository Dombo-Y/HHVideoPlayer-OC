//
//  ViewController.m
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import "ViewController.h"
#import "KxMovieViewController.h"
#import "HHVideoViewController.h"
@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
}

- (IBAction)reponseMethod:(UIButton *)sender {
    NSString *path = @"/Users/yindongbo/HHVideoPlayer-OC/HHVideoPlayer-OC/HHVideoPlayer-OC/KxMovieExapmle/output.mp4";
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    KxMovieViewController *vc = [KxMovieViewController movieViewControllerWithContentPath:path  parameters:parameters];
    
//    HHVideoViewController *vc = [[HHVideoViewController alloc] init];
    [self presentViewController:vc animated:YES completion:nil];
}


- (IBAction)responseMethodA:(UIButton *)sender {
//    NSString *path = @"/Users/yindongbo/HHVideoPlayer-OC/HHVideoPlayer-OC/HHVideoPlayer-OC/KxMovieExapmle/output.mp4";
//    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
//    KxMovieViewController *vc = [KxMovieViewController movieViewControllerWithContentPath:path  parameters:parameters];
    
    HHVideoViewController *vc = [[HHVideoViewController alloc] init];
    [self presentViewController:vc animated:YES completion:nil];
}

@end
