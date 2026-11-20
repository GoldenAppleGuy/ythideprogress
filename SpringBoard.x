// YTHideProgress, SpringBoard part (jailbreak only), for YouTube's picture in picture and the
// system's now playing players:
// - "Hide Picture in Picture Controls": when it starts, keep the controls (with their progress
//   bar) hidden instead of showing them for 3 s. Tapping the window shows them as usual.
// - "Hide Picture in Picture Bar": leave the progress bar out of the controls whenever they show
//   (a tap, a paused video); the buttons stay.
// - "Hide in Now Playing": the Lock Screen, Control Center and Dynamic Island players leave out
//   their scrubber (progress bar and times) while YouTube is the app playing, and lay out without
//   it. The Lock Screen one is drawn by MediaRemoteUI (this part loads there too); its sandbox
//   can't read YouTube's settings, so YouTube publishes the switch as a notify state.
// The switches are in YouTube's settings and read from YouTube's own preferences file (the
// picture in picture ones when it starts, the now playing one from a shared notify state).
// Other apps' picture in picture and media are left alone. Nothing here is hooked unless
// "System Players" (off by default) was on when SpringBoard started; changing it asks for a
// respring.
//
// iOS 17.0 (Pegasus in SpringBoard): on start, -[PGPictureInPictureViewController
// notePictureInPictureStartedAutomatically:] is followed at once by
// -[PGControlsContainerView _setPrefersControlsHidden:NO animated:YES] (the reveal); a timer
// hides them 3 s later. A tap makes the same call from a gesture. The progress bar in the
// controls is a PGProgressIndicator; it is kept hidden while the option is on.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define kYouTubeID @"com.google.ios.youtube"
#define kPiPKey @"YTHideProgress_pip"
#define kMasterKey @"YTHideProgress_enabled"
#define kPiPBarKey @"YTHideProgress_pipbar"
#define kLockKey @"YTHideProgress_lockscreen"
#define kSystemKey @"YTHideProgress_system"
#define kStateName "com.goldenappleguy.ythideprogress.state"

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (readonly, nonatomic) NSURL *dataContainerURL;
@end
@interface PGPictureInPictureViewController : UIViewController
@property (readonly, weak, nonatomic) id application;
@end
@interface PGControlsContainerView : UIView
@end
@interface PGProgressIndicator : UIView
@end
@interface MRUNowPlayingTimeControlsView : UIView
@end
@interface MRUNowPlayingView : UIView
@property (nonatomic) BOOL showTimeControlsView;
@end

static const void *kHideBarKey = &kHideBarKey; // on the PiP view controller

// Debug log, only in builds made with YTHP_DEBUG=1: /var/mobile/tmp/ythideprogress-sb.log
#ifdef YTHP_DEBUG
static void sbLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = [NSString stringWithFormat:@"/var/mobile/tmp/ythideprogress-%@.log", NSProcessInfo.processInfo.processName];
    if (![[NSFileManager defaultManager] isWritableFileAtPath:@"/var/mobile/tmp"])
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ythideprogress-sb.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile];
    [h writeData:[[NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), line] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}
#define SB_LOG(...) sbLog(__VA_ARGS__)
#else
#define SB_LOG(...) do {} while (0)
#endif

static CFAbsoluteTime gSuppressRevealUntil;

static NSString *bundleIDOf(PGPictureInPictureViewController *vc) {
    id app = [vc respondsToSelector:@selector(application)] ? vc.application : nil;
    if ([app respondsToSelector:@selector(bundleIdentifier)]) {
        id b = [app performSelector:@selector(bundleIdentifier)];
        if ([b isKindOfClass:[NSString class]]) return b;
    }
    return nil;
}

// The switches live in YouTube's settings, so their values are in YouTube's container.
static NSDictionary *youTubePrefs(void) {
    NSURL *container = [[objc_getClass("LSApplicationProxy") applicationProxyForIdentifier:kYouTubeID] dataContainerURL];
    if (!container) return @{};
    NSURL *plist = [container URLByAppendingPathComponent:@"Library/Preferences/com.google.ios.youtube.plist"];
    return [NSDictionary dictionaryWithContentsOfURL:plist] ?: @{};
}

// A switch, on by default, and only while the Enabled switch is on.
static BOOL optionOn(NSDictionary *prefs, NSString *key) {
    id master = prefs[kMasterKey], value = prefs[key];
    BOOL masterOn = [master respondsToSelector:@selector(boolValue)] ? [master boolValue] : YES;
    BOOL valueOn = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
    return masterOn && valueOn;
}

// The now playing switch, from the shared notify state (bit 1: set, bit 2: on), which
// MediaRemoteUI's sandbox can read. SpringBoard sets it at launch and YouTube when it changes.
static uint64_t sharedState(void) {
    static int token = -1; // kept: notifyd forgets a state nobody is registered for
    if (token == -1 && notify_register_check(kStateName, &token) != NOTIFY_STATUS_OK) token = -1;
    uint64_t state = 0;
    if (token != -1) notify_get_state(token, &state);
    return state;
}

static BOOL nowPlayingOptionOn(void) {
    uint64_t state = sharedState();
    return (state & 1) ? (state & 2) != 0 : YES;
}

// YouTube's channel filter leaves the playing video out (bit 16 of the shared state).
static BOOL videoFilteredOut(void) {
    return (sharedState() & 16) != 0;
}

// The app whose media a now playing view shows: its view controller's controller's metadata
// controller knows the bundle ID. Every step is checked, for other iOS versions.
static NSString *nowPlayingBundleID(UIView *view) {
    // The Lock Screen and Control Center players, and the Dynamic Island's (MRUActivityNowPlaying…).
    Class vcClass = objc_getClass("MRUNowPlayingViewController"), activityClass = objc_getClass("MRUActivityNowPlayingViewController");
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (![r isKindOfClass:vcClass] && !(activityClass && [r isKindOfClass:activityClass])) continue;
        id controller = [r respondsToSelector:@selector(controller)] ? [r performSelector:@selector(controller)] : nil;
        id metadata = [controller respondsToSelector:NSSelectorFromString(@"metadataController")] ? [controller performSelector:NSSelectorFromString(@"metadataController")] : nil;
        id bundleID = [metadata respondsToSelector:NSSelectorFromString(@"bundleID")] ? [metadata performSelector:NSSelectorFromString(@"bundleID")] : nil;
        // iOS 14: no controller; the view controller's endpoint controller
        // (MediaControlsEndpointController) knows the app.
        if (![bundleID isKindOfClass:[NSString class]]) {
            id endpoint = [r respondsToSelector:NSSelectorFromString(@"endpointController")] ? [r performSelector:NSSelectorFromString(@"endpointController")] : nil;
            for (NSString *key in @[@"bundleID", @"representedBundleID"]) {
                bundleID = [endpoint respondsToSelector:NSSelectorFromString(key)] ? [endpoint performSelector:NSSelectorFromString(key)] : nil;
                if ([bundleID isKindOfClass:[NSString class]]) break;
            }
        }
        return [bundleID isKindOfClass:[NSString class]] ? bundleID : nil;
    }
#ifdef YTHP_DEBUG
    static NSMutableSet *logged;
    if (!logged) logged = [NSMutableSet set];
    NSMutableString *chain = [NSMutableString string];
    for (UIResponder *r = view; r; r = r.nextResponder) [chain appendFormat:@" > %@", r.class];
    if (![logged containsObject:chain]) { [logged addObject:chain]; SB_LOG(@"no app for %@:%@", view.class, chain); }
#endif
    return nil;
}

static BOOL hidesNowPlayingTime(UIView *view) {
    return [nowPlayingBundleID(view) isEqualToString:kYouTubeID] && nowPlayingOptionOn();
}

// Whether the picture in picture that a view belongs to leaves out its progress bar.
static BOOL hidesBar(UIView *view) {
    Class vcClass = objc_getClass("PGPictureInPictureViewController");
    for (UIResponder *r = view; r; r = r.nextResponder)
        if ([r isKindOfClass:vcClass]) return [objc_getAssociatedObject(r, kHideBarKey) boolValue];
    return NO;
}

%hook PGPictureInPictureViewController
- (void)notePictureInPictureStartedAutomatically:(BOOL)automatically {
    BOOL youTube = [bundleIDOf(self) isEqualToString:kYouTubeID] && !videoFilteredOut();
    NSDictionary *prefs = youTube ? youTubePrefs() : nil;
    BOOL suppress = youTube && optionOn(prefs, kPiPKey);
    BOOL hideBar = youTube && optionOn(prefs, kPiPBarKey);
    objc_setAssociatedObject(self, kHideBarKey, hideBar ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SB_LOG(@"start youTube=%d hideControls=%d hideBar=%d", youTube, suppress, hideBar);
    if (suppress) gSuppressRevealUntil = CFAbsoluteTimeGetCurrent() + 2;
    %orig;
}
%end

%hook PGControlsContainerView
- (void)_setPrefersControlsHidden:(BOOL)hidden animated:(BOOL)animated {
    if (!hidden && CFAbsoluteTimeGetCurrent() < gSuppressRevealUntil) {
        gSuppressRevealUntil = 0; // only the reveal that comes with the start
        %orig(YES, NO);
        return;
    }
    %orig;
}
%end

%hook PGProgressIndicator
- (void)setHidden:(BOOL)hidden {
    %orig(hidden || hidesBar(self));
}
- (void)didMoveToWindow {
    %orig;
    if (self.window && hidesBar(self)) {
        SB_LOG(@"progress bar left out");
        self.hidden = YES;
    }
}
- (void)layoutSubviews {
    %orig;
    if (!self.hidden && hidesBar(self)) self.hidden = YES;
}
%end

// What MediaRemoteUI last asked for, so the scrubber comes back when the rule stops applying.
static const void *kWantsHiddenKey = &kWantsHiddenKey;

%hook MRUNowPlayingTimeControlsView
- (void)setHidden:(BOOL)hidden {
    objc_setAssociatedObject(self, kWantsHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(hidden || hidesNowPlayingTime(self));
}
- (void)layoutSubviews {
    %orig;
    BOOL hide = hidesNowPlayingTime(self);
    BOOL wantsHidden = [objc_getAssociatedObject(self, kWantsHiddenKey) boolValue];
    SB_LOG(@"time controls app=%@ hide=%d wantsHidden=%d hidden=%d", nowPlayingBundleID(self), hide, wantsHidden, self.hidden);

    if (self.hidden != (hide || wantsHidden)) {
        // Through the hook, without changing what MediaRemoteUI asked for.
        self.hidden = wantsHidden;
        objc_setAssociatedObject(self, kWantsHiddenKey, @(wantsHidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
%end


// Without the scrubber row the player lays out shorter: MRUNowPlayingView's own
// showTimeControlsView switch, kept off while YouTube plays. What MediaRemoteUI asked for is
// remembered, so the row comes back for other apps.
static const void *kWantsTimeKey = &kWantsTimeKey;
static BOOL gApplyingTime;

static NSHashTable<MRUNowPlayingView *> *nowPlayingViews(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

static void applyTimeRow(MRUNowPlayingView *view) {
    // iOS 14's MRUNowPlayingView has no such switch (calling it throws in SpringBoard): there the
    // row is only hidden (MRUNowPlayingTimeControlsView hooks) and the player keeps its height.
    if (![view respondsToSelector:@selector(showTimeControlsView)] || ![view respondsToSelector:@selector(setShowTimeControlsView:)]) return;
    [nowPlayingViews() addObject:view];
    NSNumber *wants = objc_getAssociatedObject(view, kWantsTimeKey);
    BOOL show = (wants ? wants.boolValue : YES) && !hidesNowPlayingTime(view);
    if (view.showTimeControlsView == show) return;
    SB_LOG(@"time row %@ (app=%@)", show ? @"back" : @"left out", nowPlayingBundleID(view));
    gApplyingTime = YES;
    view.showTimeControlsView = show;
    gApplyingTime = NO;
    UIView *timeControls = [view respondsToSelector:NSSelectorFromString(@"timeControlsView")] ? [view valueForKey:@"timeControlsView"] : nil;
    [timeControls setNeedsLayout]; // un-hides itself if it was only hidden by this rule
    [view invalidateIntrinsicContentSize];
    [view.superview setNeedsLayout];
    // Hosts that size the player once (the Lock Screen and Notification Center platter in
    // MediaRemoteUI) re-measure when the player's view controller tells its delegate.
    SEL sizeChanged = NSSelectorFromString(@"nowPlayingViewController:didChangeSizeWithAnimations:completion:");
    Class vcClass = objc_getClass("MRUNowPlayingViewController");
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (![r isKindOfClass:vcClass]) continue;
        id delegate = [r respondsToSelector:@selector(delegate)] ? [r performSelector:@selector(delegate)] : nil;
        SB_LOG(@"size change to %@", NSStringFromClass([delegate class]));
        if ([delegate respondsToSelector:sizeChanged])
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, sizeChanged, r, ^{ [view.superview layoutIfNeeded]; }, ^(BOOL finished) {});
        break;
    }
}

%hook MRUNowPlayingView
- (void)setShowTimeControlsView:(BOOL)show {
    if (gApplyingTime) {
        %orig;
        return;
    }
    objc_setAssociatedObject(self, kWantsTimeKey, @(show), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(show && !hidesNowPlayingTime(self));
}
- (void)layoutSubviews {
    applyTimeRow(self);
    %orig;
}
%end

// The Dynamic Island's expanded player (MRUActivityNowPlayingView, in MediaRemoteUI) has no
// switch for its scrubber row: with the row hidden, move what's below it up and report the
// island that much shorter.
@interface MRUActivityNowPlayingView : UIView
- (UIView *)timeControlsView;
@end

// Only while the tweak is what hides the row: not when MediaRemoteUI hides it itself (it then
// lays out without it already).
static CGFloat removedTimeRowHeight(MRUActivityNowPlayingView *view) {
    UIView *time = [view respondsToSelector:@selector(timeControlsView)] ? view.timeControlsView : nil;
    if (!time || !hidesNowPlayingTime(time) || [objc_getAssociatedObject(time, kWantsHiddenKey) boolValue]) return 0;
    return time.frame.size.height;
}

static const void *kShiftedYKey = &kShiftedYKey; // on a moved subview: the y the tweak gave it

%hook MRUActivityNowPlayingView
- (void)layoutSubviews {
    %orig;
    UIView *time = [self respondsToSelector:@selector(timeControlsView)] ? self.timeControlsView : nil;
    CGFloat h = removedTimeRowHeight(self);
    SB_LOG(@"island layout time=%@ remove=%.1f height=%.1f", time ? NSStringFromCGRect(time.frame) : @"-", h, self.bounds.size.height);
    if (h <= 0) return;
    CGFloat below = CGRectGetMaxY(time.frame) - 1;
    for (UIView *sub in self.subviews) {
        if (sub == time) continue;
        // A view the original layout left where the tweak put it last time is not moved again.
        NSNumber *shifted = objc_getAssociatedObject(sub, kShiftedYKey);
        if (shifted && fabs(sub.frame.origin.y - shifted.doubleValue) < 0.5) continue;
        if (sub.frame.origin.y < below) continue;
        CGRect f = sub.frame;
        f.origin.y -= h;
        sub.frame = f;
        objc_setAssociatedObject(sub, kShiftedYKey, @(f.origin.y), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
- (double)preferredHeightForBottomSafeArea {
    double height = %orig;
    CGFloat h = removedTimeRowHeight(self);
    SB_LOG(@"island preferred height %.1f - %.1f", height, h);
    return height - h;
}
%end

// The state YouTube and this part share (see nowPlayingOptionOn): bit 1 set, bit 2 hide in now
// playing, bit 4 the System Players switch as SpringBoard loaded it, bit 8 this part is installed.
#define kRespringName "com.goldenappleguy.ythideprogress.respring"
static BOOL gSystemLoaded; // whether the hooks were installed in this process

// --- Crash guard ---
// If SpringBoard goes down twice in a row soon after the System Players hooks went in, they stay
// out (paused) until the switch is turned off and on in YouTube. A restart counts only if
// SpringBoard left a crash report after that start (a hang leaves one too, when the watchdog
// ends it), so resprings for installs or tests don't. Read and written at SpringBoard's start
// with plain C only: the loader is still running there.
#define kGuardDir "/var/mobile/Documents/YTHideProgress"
#define kGuardFile kGuardDir "/guard"
#define kGuardWindow 300   // seconds: a hang is ended by the watchdog after about 3 minutes
#define kGuardLimit 2
static BOOL gGuardPaused;
static long gStartTime;

typedef struct { long start; int hooks, quick, paused; } GuardState;

static GuardState readGuard(void) {
    GuardState g = {0, 0, 0, 0};
    FILE *f = fopen(kGuardFile, "r");
    if (!f) return g;
    if (fscanf(f, "%ld %d %d %d", &g.start, &g.hooks, &g.quick, &g.paused) != 4) memset(&g, 0, sizeof g);
    fclose(f);
    return g;
}

static void writeGuard(GuardState g) {
    mkdir(kGuardDir, 0755);
    FILE *f = fopen(kGuardFile, "w");
    if (!f) return;
    fprintf(f, "%ld %d %d %d\n", g.start, g.hooks, g.quick, g.paused);
    fclose(f);
}

// Whether SpringBoard left a crash report (SpringBoard-*.ips) at or after a time.
static BOOL springBoardCrashedSince(long since) {
    DIR *dir = opendir("/var/mobile/Library/Logs/CrashReporter");
    if (!dir) return NO;
    BOOL found = NO;
    struct dirent *e;
    while (!found && (e = readdir(dir))) {
        size_t n = strlen(e->d_name);
        if (strncmp(e->d_name, "SpringBoard-", 12) != 0 || n < 4 || strcmp(e->d_name + n - 4, ".ips") != 0) continue;
        char path[512];
        snprintf(path, sizeof path, "/var/mobile/Library/Logs/CrashReporter/%s", e->d_name);
        struct stat st;
        if (stat(path, &st) == 0 && st.st_mtime >= since) found = YES;
    }
    closedir(dir);
    return found;
}

// At SpringBoard's start: count the last run if it ended in a crash soon after the hooks went in.
static void checkGuard(void) {
    gStartTime = (long)time(NULL);
    GuardState g = readGuard();
    if (g.paused) {
        gGuardPaused = YES;
    } else {
        BOOL quickCrash = g.hooks && g.start && gStartTime - g.start < kGuardWindow && springBoardCrashedSince(g.start);
        g.quick = quickCrash ? g.quick + 1 : 0;
        if (g.quick >= kGuardLimit) g.paused = 1;
        gGuardPaused = g.paused != 0;
    }
    g.start = gStartTime;
    g.hooks = 0; // set once the hooks are in
    writeGuard(g);
}

static void noteHooksInstalled(void) {
    GuardState g = readGuard();
    g.start = gStartTime;
    g.hooks = 1;
    writeGuard(g);
}

// Turning System Players on again (after a pause) clears the guard.
static void clearGuard(void) {
    unlink(kGuardFile);
}

static void publishLaunchState(NSDictionary *prefs) {
    static int token = -1; // kept: notifyd forgets a state nobody is registered for
    if (token == -1 && notify_register_check(kStateName, &token) != NOTIFY_STATUS_OK) { token = -1; return; }
    // What YouTube published is newer than its preferences file, which can lag behind.
    uint64_t old = sharedState();
    BOOL lockOn = (old & 1) ? (old & 2) != 0 : optionOn(prefs, kLockKey);
    // Bit 32: the hooks are paused after crashes (YouTube's settings say so).
    uint64_t state = 1 | 8 | (lockOn ? 2 : 0) | (gSystemLoaded ? 4 : 0) | (old & 16) | (gGuardPaused ? 32 : 0);
    notify_set_state(token, state);
    notify_post(kStateName);
}

// System Players: the value YouTube sent with its last respring request (state 1 off, 2 on),
// else the preferences file.
static BOOL systemWanted(NSDictionary *prefs) {
    static int token = -1; // kept, so the value outlives the respring
    uint64_t asked = 0;
    if (token == -1 && notify_register_check(kRespringName, &token) != NOTIFY_STATUS_OK) token = -1;
    if (token != -1) notify_get_state(token, &asked);
    if (asked) return asked == 2;
    id value = prefs[kSystemKey];
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static NSString *frontmostBundleID(void) {
    id app = [UIApplication sharedApplication];
    SEL front = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    id frontApp = [app respondsToSelector:front] ? ((id (*)(id, SEL))objc_msgSend)(app, front) : nil;
    SB_LOG(@"front: responds=%d app=%@", [app respondsToSelector:front], frontApp);
    id bundleID = [frontApp respondsToSelector:@selector(bundleIdentifier)] ? [frontApp performSelector:@selector(bundleIdentifier)] : nil;
    return [bundleID isKindOfClass:[NSString class]] ? bundleID : nil;
}

static void relaunchSpringBoard(void) {
    id app = [UIApplication sharedApplication];
    SEL relaunch = NSSelectorFromString(@"_relaunchSpringBoardNow");
    if ([app respondsToSelector:relaunch]) ((void (*)(id, SEL))objc_msgSend)(app, relaunch);
    else exit(0);
}

// The hooks, and the state watcher that re-applies them when YouTube changes a switch.
static void installHooks(void) {
    %init;
    // YouTube posts the state when the Enabled or Hide in Now Playing switch changes: apply it to
    // every player now, not at its next layout.
    int token;
    notify_register_dispatch(kStateName, &token, dispatch_get_main_queue(), ^(int t) {
        for (MRUNowPlayingView *view in nowPlayingViews().allObjects) {
            applyTimeRow(view);
            UIView *timeControls = [view respondsToSelector:NSSelectorFromString(@"timeControlsView")] ? [view valueForKey:@"timeControlsView"] : nil;
            [timeControls setNeedsLayout];
            [view setNeedsLayout];
        }
    });
}

// SpringBoard's part, once SpringBoard has finished launching: finding YouTube's container goes
// through LaunchServices, which deadlocks SpringBoard when called while libraries are still
// loading (seen on iOS 15 with Dopamine: the watchdog then reboots userspace).
static void startSpringBoardPart(void) {
    // System Players (off by default) decides, at each respring, whether anything outside
    // YouTube is changed. SpringBoard reads it from YouTube's settings and shares it.
    NSDictionary *prefs = youTubePrefs();
    BOOL wantedAtLaunch = systemWanted(prefs);
    if (!wantedAtLaunch && gGuardPaused) { clearGuard(); gGuardPaused = NO; } // switched off: nothing to pause
    gSystemLoaded = wantedAtLaunch && !gGuardPaused;
    publishLaunchState(prefs);
    // YouTube asks for the respring after the switch changes; only a real change is applied.
    int respringToken;
    // The request is a public notification: only honoured while YouTube is in front (its
    // settings page is where it comes from), so another app can't respring the phone.
    notify_register_dispatch(kRespringName, &respringToken, dispatch_get_main_queue(), ^(int t) {
        BOOL wanted = systemWanted(nil);
        NSString *front = frontmostBundleID();
        SB_LOG(@"respring asked, wanted=%d loaded=%d front=%@", wanted, gSystemLoaded, front);
        if (wanted != gSystemLoaded && [front isEqualToString:kYouTubeID]) {
            if (wanted) clearGuard(); // turned on again: try the hooks again
            relaunchSpringBoard();
        }
    });
    SB_LOG(@"system players %@%@", gSystemLoaded ? @"on" : @"off", gGuardPaused ? @" (paused after crashes)" : @"");
    if (gSystemLoaded) {
        installHooks();
        noteHooksInstalled();
    }
}

%ctor {
    // Nothing here may wait on another process or load more libraries: it runs while the
    // jailbreak is still loading tweaks.
    BOOL springBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    if (springBoard) {
        checkGuard();
        __block id observer = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
                observer = nil;
                startSpringBoardPart();
            }];
        return;
    }
    // MediaRemoteUI can't read YouTube's settings: it follows what SpringBoard loaded, and
    // quits (to be started again as needed) when a respring changes that.
    int token;
    uint64_t state = 0;
    if (notify_register_check(kStateName, &token) == NOTIFY_STATUS_OK) notify_get_state(token, &state);
    gSystemLoaded = (state & 4) != 0;
    int watchToken;
    notify_register_dispatch(kStateName, &watchToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t now = 0;
        notify_get_state(t, &now);
        if (((now & 4) != 0) != gSystemLoaded && (now & 8)) exit(0);
    });
    if (gSystemLoaded) installHooks();
}
