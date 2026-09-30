#import "ReaderLockMonoCC.h"
#import "../Common/ReaderLockShared.h"

@implementation ReaderLockMonoCC

- (BOOL)isSelected {
    return RLReadDarwinState() == RLReaderStateMono;
}

- (void)setSelected:(BOOL)selected {
    if (selected && RLReadDarwinState() == RLReaderStateOff) {
        RLPostCommand(RLCommandMonoNotification);
    }
    [super refreshState];
}

- (UIImage *)iconGlyph {
    UIImage *image = [UIImage systemImageNamed:@"book.closed.fill"];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIColor *)selectedColor {
    return [UIColor systemGrayColor];
}

@end
