#import "RNSScreenStack.h"
#import "RNSScreen.h"
#import "RNSScreenStackHeaderConfig.h"

#import <React/RCTBridge.h>
#import <React/RCTUIManager.h>
#import <React/RCTUIManagerUtils.h>

@interface RNSScreenStackView () <UINavigationControllerDelegate>

@end

@implementation RNSScreenStackView {
  BOOL _needUpdate;
  UINavigationController *_controller;
  NSMutableArray<RNSScreenView *> *_reactSubviews;
  NSMutableSet<RNSScreenView *> *_dismissedScreens;
  NSMutableArray<UIViewController *> *_presentedModals;
  __weak RNSScreenStackManager *_manager;
}

- (instancetype)initWithManager:(RNSScreenStackManager*)manager
{
  if (self = [super init]) {
    _manager = manager;
    _reactSubviews = [NSMutableArray new];
    _presentedModals = [NSMutableArray new];
    _dismissedScreens = [NSMutableSet new];
    _controller = [[UINavigationController alloc] init];
    _controller.delegate = self;
    _needUpdate = NO;
    [self addSubview:_controller.view];
  }
  return self;
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
  UIView *view = viewController.view;
  for (UIView *subview in view.reactSubviews) {
    if ([subview isKindOfClass:[RNSScreenStackHeaderConfig class]]) {
      [((RNSScreenStackHeaderConfig*) subview) willShowViewController:viewController];
      break;
    }
  }
}

- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
  for (NSUInteger i = _reactSubviews.count - 1; i >= 0; i--) {
    if ([viewController isEqual:[_reactSubviews objectAtIndex:i].controller]) {
      break;
    } else {
      // TODO: send dismiss event
      [_dismissedScreens addObject:[_reactSubviews objectAtIndex:i]];
    }
  }
}

- (void)markUpdated
{
  // We want 'updateContainer' to be executed on main thread after all enqueued operations in
  // uimanager are complete. In order to achieve that we enqueue call on UIManagerQueue from which
  // we enqueue call on the main queue. This seems to be working ok in all the cases I've tried but
  // there is a chance it is not the correct way to do that.
  if (!_needUpdate) {
    _needUpdate = YES;
    RCTExecuteOnUIManagerQueue(^{
      RCTExecuteOnMainQueue(^{
        _needUpdate = NO;
        [self updateContainer];
      });
    });
  }
}

- (void)markChildUpdated
{
  // do nothing
}

- (void)didUpdateChildren
{
  // do nothing
}

- (void)insertReactSubview:(RNSScreenView *)subview atIndex:(NSInteger)atIndex
{
  [_reactSubviews insertObject:subview atIndex:atIndex];
  [self markUpdated];
}

- (void)removeReactSubview:(RNSScreenView *)subview
{
  [_reactSubviews removeObject:subview];
  [_dismissedScreens removeObject:subview];
  [self markUpdated];
}

- (NSArray<UIView *> *)reactSubviews
{
  return _reactSubviews;
}

- (void)didUpdateReactSubviews
{
  // do nothing
}

- (void)setModalViewControllers:(NSArray<UIViewController *> *) controllers
{
  NSMutableArray<UIViewController *> *newControllers = [NSMutableArray arrayWithArray:controllers];
  [newControllers removeObjectsInArray:_presentedModals];
  [newControllers removeObject:controllers.firstObject];

  NSMutableArray<UIViewController *> *controllersToRemove = [NSMutableArray arrayWithArray:_presentedModals];
  [controllersToRemove removeObjectsInArray:controllers];

  [_controller setViewControllers:@[controllers.firstObject]];

  // presenting new controllers
  for (UIViewController *newController in newControllers) {
    [_presentedModals addObject:newController];
    newController.modalPresentationStyle = UIModalPresentationCurrentContext;
    if (_controller.presentedViewController != nil) {
      [_controller.presentedViewController presentViewController:newController animated:YES completion:nil];
    } else {
      [_controller presentViewController:newController animated:YES completion:nil];
    }
  }

  // hiding old controllers
  for (UIViewController *controller in [controllersToRemove reverseObjectEnumerator]) {
    [_presentedModals removeObject:controller];
    if (controller.presentedViewController != nil) {
      UIViewController *restore = controller.presentedViewController;
      UIViewController *parent = controller.presentingViewController;
      [controller dismissViewControllerAnimated:NO completion:^{
        [parent dismissViewControllerAnimated:NO completion:^{
          [parent presentViewController:restore animated:NO completion:nil];
        }];
      }];
    } else {
      [controller.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    }
  }
}

- (void)setStackViewControllers:(NSArray<UIViewController *> *)controllers
{
  UIViewController *top = controllers.lastObject;
  if (_controller.viewControllers.count == 0) {
    // nothing pushed yet
    [_controller setViewControllers:@[top] animated:NO];
  } else if (top != _controller.viewControllers.lastObject) {
    if (![controllers containsObject:_controller.viewControllers.lastObject]) {
      // last top controller is no longer on stack
      // in this case we set the controllers stack to the new list with
      // added the last top element to it and perform animated pop
      NSMutableArray *newControllers = [NSMutableArray arrayWithArray:controllers];
      [newControllers addObject:_controller.viewControllers.lastObject];
      [_controller setViewControllers:newControllers animated:NO];
      [_controller popViewControllerAnimated:YES];
    } else if (![_controller.viewControllers containsObject:top]) {
      // new top controller is not on the stack
      // in such case we update the stack except from the last element with
      // no animation and do animated push of the last item
      NSMutableArray *newControllers = [NSMutableArray arrayWithArray:controllers];
      [newControllers removeLastObject];
      [_controller setViewControllers:newControllers animated:NO];
      [_controller pushViewController:top animated:YES];
    } else {
      // don't really know what this case could be, but may need to handle it
      // somehow
      [_controller setViewControllers:controllers animated:YES];
    }
  } else {
    [_controller setViewControllers:controllers animated:NO];
  }
}

- (void)updateContainer
{
  NSMutableArray<UIViewController *> *controllers = [NSMutableArray new];
  for (RNSScreenView *screen in _reactSubviews) {
    if (![_dismissedScreens containsObject:screen]) {
      [controllers addObject:screen.controller];
    }
  }

  [self setStackViewControllers:controllers];
//  [self setModalViewControllers:controllers];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  [self reactAddControllerToClosestParent:_controller];
  _controller.view.frame = self.bounds;
}

@end


@implementation RNSScreenStackManager

RCT_EXPORT_MODULE()

RCT_EXPORT_VIEW_PROPERTY(transitioning, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(progress, CGFloat)

- (UIView *)view
{
  return [[RNSScreenStackView alloc] initWithManager:self];
}

@end