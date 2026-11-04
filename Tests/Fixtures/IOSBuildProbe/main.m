#import <UIKit/UIKit.h>
#import <os/log.h>
@interface ProbeController : UIViewController <UITextViewDelegate, UIScrollViewDelegate>
@property NSInteger taps, drags;
@property BOOL appeared;
@property(strong) UILabel *status;
@property(strong) UITextView *editor;
@property(strong) UIScrollView *scroller;
@end
@implementation ProbeController
- (void)save {
    NSDictionary *receipt = @{@"ready": @(self.appeared), @"editing": @(self.editor.isFirstResponder), @"taps": @(self.taps), @"drags": @(self.drags), @"text": self.editor.text ?: @"", @"scroll": @(self.scroller.contentOffset.y), @"width": @(self.view.bounds.size.width), @"height": @(self.view.bounds.size.height)};
    NSString *file = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"control.json"];
    [[NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil] writeToFile:file atomically:YES];
    self.status.text = [NSString stringWithFormat:@"点击 %ld · 拖动 %ld", (long)self.taps, (long)self.drags];
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemTealColor;
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, 65, 340, 50)]; self.status.font = [UIFont systemFontOfSize:24]; [self.view addSubview:self.status];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; button.frame = CGRectMake(24, 120, 340, 60); button.backgroundColor = UIColor.whiteColor; [button setTitle:@"点击计数 / 收起键盘" forState:UIControlStateNormal]; [button addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside]; [self.view addSubview:button];
    self.editor = [[UITextView alloc] initWithFrame:CGRectMake(24, 200, 340, 110)]; self.editor.font = [UIFont systemFontOfSize:22]; self.editor.delegate = self; self.editor.accessibilityLabel = @"QA 文字输入"; self.editor.autocorrectionType = UITextAutocorrectionTypeNo; self.editor.smartQuotesType = UITextSmartQuotesTypeNo; self.editor.smartDashesType = UITextSmartDashesTypeNo; [self.view addSubview:self.editor];
    UILabel *drag = [[UILabel alloc] initWithFrame:CGRectMake(24, 335, 340, 100)]; drag.text = @"在这里拖动"; drag.textAlignment = NSTextAlignmentCenter; drag.backgroundColor = UIColor.systemYellowColor; drag.userInteractionEnabled = YES; [drag addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]]; [self.view addSubview:drag];
    self.scroller = [[UIScrollView alloc] initWithFrame:CGRectMake(24, 460, 340, 240)]; self.scroller.backgroundColor = UIColor.systemBackgroundColor; self.scroller.contentSize = CGSizeMake(340, 1400); self.scroller.delegate = self;
    for (int i = 0; i < 20; i++) { UILabel *line = [[UILabel alloc] initWithFrame:CGRectMake(16, i * 70, 300, 65)]; line.text = [NSString stringWithFormat:@"滚动测试第 %d 行", i + 1]; [self.scroller addSubview:line]; }
    [self.view addSubview:self.scroller]; [self save];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self save]; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; self.appeared = YES; [self save]; }
- (void)tap { self.taps++; [self.view endEditing:YES]; [self save]; }
- (void)pan:(UIPanGestureRecognizer *)gesture { if (gesture.state == UIGestureRecognizerStateEnded) { self.drags++; [self save]; } }
- (void)textViewDidChange:(UITextView *)textView { [self save]; }
- (void)textViewDidBeginEditing:(UITextView *)textView { [self save]; }
- (void)textViewDidEndEditing:(UITextView *)textView { [self save]; }
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { [self save]; }
@end
@interface ProbeScene : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation ProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeController new]; [self.window makeKeyAndVisible];
    os_log_error(OS_LOG_DEFAULT, "LOGCAT_MINI_APP_PATH_QA synthetic fixture");
}
@end
@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"QA" sessionRole:session.role];
    configuration.delegateClass = ProbeScene.class;
    return configuration;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class)); }
}
