// spaces: what WallpaperAgent says each Space in the store shows on each display, through the legacy client AppKit uses
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ColorSync/ColorSync.h>
extern CFUUIDRef CGDisplayCreateUUIDFromDisplayID(uint32_t);
#import <dlfcn.h>
@interface WPSWallpaperServicesClient : NSObject
- (id)legacyDesktopPictureForSpace:(id)space displayID:(uint32_t)display error:(NSError **)error;
- (NSURL *)imageURLForSpace:(id)space displayID:(uint32_t)display error:(NSError **)error;
@end
int main() {
    dlopen("/System/Library/PrivateFrameworks/WallpaperServices.framework/WallpaperServices", RTLD_NOW);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/com.apple.wallpaper/Store/Index.plist"];
    NSDictionary *store = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:path] options:0 format:nil error:nil];
    NSArray *spaces = [[store[@"Spaces"] allKeys] sortedArrayUsingSelector:@selector(compare:)];
    CGDirectDisplayID ids[8]; uint32_t n = 0; CGGetActiveDisplayList(8, ids, &n);
    WPSWallpaperServicesClient *client = [[NSClassFromString(@"WPSWallpaperServicesClient") alloc] init];
    for (uint32_t i = 0; i < n; i++) {
        CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(ids[i]);
        NSString *uuid = CFBridgingRelease(CFUUIDCreateString(NULL, u)); CFRelease(u);
        for (NSString *space in spaces) {
            if (!store[@"Spaces"][space][@"Displays"][uuid]) continue;
            NSError *e = nil;
            NSURL *url = [client imageURLForSpace:space displayID:ids[i] error:&e];
            printf("%s  space %-36s  %s\n", [[uuid substringToIndex:8] UTF8String], [space UTF8String], url ? [[url.path stringByReplacingOccurrencesOfString:[NSHomeDirectory() stringByAppendingString:@"/Library/Application Support/"] withString:@""] UTF8String] : [[e description] UTF8String]);
        }
    }
}
