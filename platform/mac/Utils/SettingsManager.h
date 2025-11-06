#import <Foundation/Foundation.h>

// 设置管理器 - 负责settings.json的读写和最近文件列表的持久化
@interface SettingsManager : NSObject

@property(nonatomic, strong) NSMutableDictionary* settingsDict;
@property(nonatomic, strong) NSMutableArray<NSString*>* recentPaths;

- (NSString*)settingsJSONPath;
- (void)loadSettingsJSON;
- (void)saveSettingsJSON;
- (void)extractRecentFromSettings;
- (void)persistRecentIntoSettings;

@end

