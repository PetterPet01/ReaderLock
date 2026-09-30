#import "ReaderLockColorCC.h"
#import "../Common/ReaderLockShared.h"

@implementation ReaderLockColorCC

- (BOOL)isSelected {
    return RLReadDarwinState() == RLReaderStateColor;
}

- (void)setSelected:(BOOL)selected {
    if (selected && RLReadDarwinState() == RLReaderStateOff) {
        RLPostCommand(RLCommandColorNotification);
    }
    [super refreshState];
}

- (UIImage *)iconGlyph {
    UIImage *image = [UIImage systemImageNamed:@"paintpalette.fill"];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIColor *)selectedColor {
    return [UIColor systemBlueColor];
}

@end
