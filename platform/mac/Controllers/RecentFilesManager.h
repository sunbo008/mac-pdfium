#import <Cocoa/Cocoa.h>

@class SettingsManager;
@class AppDelegate;

// 最近文件管理器 - 负责最近文件列表和菜单的管理
@interface RecentFilesManager : NSObject

@property(nonatomic, weak) AppDelegate* appDelegate;
@property(nonatomic, strong) SettingsManager* settingsManager;
@property(nonatomic, strong) NSMenu* recentMenu;
@property(nonatomic, strong) NSMenuItem* recentMenuItem;

- (void)rebuildRecentMenu;
- (void)addRecentPath:(NSString*)path;
- (IBAction)openRecent:(id)sender;
- (IBAction)clearRecent:(id)sender;

@end

