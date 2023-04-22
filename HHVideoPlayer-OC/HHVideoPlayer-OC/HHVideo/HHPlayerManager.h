//
//  HHPlayerManager.h
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HHPlayerManager : NSObject

+ (instancetype)sharedInstance;

- (void)playerManagerWithContentPath:(NSString *)path targetView:(id)view;

- (void)play;
- (void)pause;
@end

NS_ASSUME_NONNULL_END
