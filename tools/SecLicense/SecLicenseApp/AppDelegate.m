#import "AppDelegate.h"
#import "ViewController.h"
#import "IssueViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    IssueViewController *issue = [[IssueViewController alloc] init];
    issue.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"发码" image:nil tag:0];

    ViewController *activate = [[ViewController alloc] init];
    activate.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"本机激活" image:nil tag:1];

    UINavigationController *issueNav = [[UINavigationController alloc] initWithRootViewController:issue];
    UINavigationController *actNav = [[UINavigationController alloc] initWithRootViewController:activate];

    UITabBarController *tabs = [[UITabBarController alloc] init];
    tabs.viewControllers = @[issueNav, actNav];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
