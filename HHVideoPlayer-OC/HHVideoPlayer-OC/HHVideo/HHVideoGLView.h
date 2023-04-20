//
//  HHVideoGLView.h
//  HHVideoPlayer-OC
//
//  Created by 尹东博 on 2023/4/19.
//

#import <UIKit/UIKit.h>
#import "HHVideoDecoder.h"
#import "HHVideoModel.h"

NS_ASSUME_NONNULL_BEGIN

@interface HHVideoGLView : UIView


- (id) initWithFrame:(CGRect)frame decoder: (HHVideoDecoder *) decoder;

- (void)render:(HHVideoFrame *) frame;
@end

NS_ASSUME_NONNULL_END
