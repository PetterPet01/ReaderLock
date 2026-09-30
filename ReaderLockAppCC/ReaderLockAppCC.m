#import "ReaderLockAppCC.h"
#import "../Common/ReaderLockShared.h"

@implementation ReaderLockAppCC

- (BOOL)isSelected {
    return RLPreferredReader() == RLReaderAppMaple;
}

- (void)setSelected:(BOOL)selected {
    // The choice is fixed for a session. Switching while locked in would desync the firewall.
    if (RLReadDarwinState() == RLReaderStateOff) {
        if (!RLWritePreferredReader(selected ? RLReaderAppMaple : RLReaderAppBooks)) {
            NSLog(@"[ReaderLock] could not save reader choice");
        }
    }
    [super refreshState];
}

- (UIImage *)iconGlyph {
    UIImage *image = [UIImage systemImageNamed:@"book.fill"];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIColor *)selectedColor {
    return [UIColor systemGreenColor];
}

@end
