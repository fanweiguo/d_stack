//
//  DActionManager.m
//  
//
//  Created by TAL on 2020/1/16.
//

#import "DStack.h"
#import "DActionManager.h"
#import "DNodeManager.h"
#import "DStackPlugin.h"

@implementation DActionManager

+ (void)handlerActionWithNodeList:(NSArray<DNode *> *)nodeList node:(nonnull DNode *)node
{
    // didPop 不处理跳转，只需要删节点
    switch (node.action) {
        case DNodeActionTypePush:
        case DNodeActionTypePresent:
        {
            [self enterPageWithNode:node];
            break;
        }
        case DNodeActionTypePop:
        case DNodeActionTypeDismiss:
        {
            [self closePageWithNode:node willRemovedList:nodeList];
            break;
        }
        case DNodeActionTypeGesture:
        {
            [self gesture:node willRemovedList:nodeList];
            break;
        }
        case DNodeActionTypePopTo:
        case DNodeActionTypePopToRoot:
        case DNodeActionTypePopToNativeRoot:
        case DNodeActionTypePopSkip:
        {
            [self closePageListWithNode:node willRemovedList:nodeList];
            break;
        }
        default:break;
    }
}

+ (void)gesture:(DNode *)node willRemovedList:(NSArray<DNode *> *)nodeList
{
    DNode *preNode = [DNodeManager sharedInstance].preNode;
    DNode *currentNode = [DNodeManager sharedInstance].currentNode;
    if (preNode && currentNode) {
        if (currentNode.pageType == DNodePageTypeFlutter &&
            preNode.pageType == DNodePageTypeNative) {
            // 当前是flutter页面，上一个页面时native页面，要通知flutter pop回一个页面
            DNode *popNode = [[DNode alloc] init];
            popNode.params = node.params;
            popNode.action = DNodeActionTypeGesture;
            [self sendMessageToFlutterWithFlutterNodes:nodeList
                                                  node:popNode];
        }
    }
}

+ (NSDictionary *)getPageTypeNodeList:(NSArray<DNode *> *)nodeList
{
    NSString *pageTypeKey = [NSString stringWithFormat:@"%@", nodeList.firstObject.target];
    NSString *pageType = nodeList.firstObject.pageTypeString;
    return @{pageTypeKey : pageType};
}

/// 进入一个页面
/// @param node 目标页面指令
+ (void)enterPageWithNode:(DNode *)node
{
    if (node.fromFlutter) {
       // 只处理来自Flutter消息通道的Node，并且是打开Native页面
       if (node.pageType == DNodePageTypeNative) {
           // flutter打开naive页面
           DStackNode *stackNode = [self stackNodeFromNode:node];
           if (node.action == DNodeActionTypePush) {
               [self dStackSafe:@selector(dStack:pushWithNode:) exe:^(DStack *stack) {
                   [stack.delegate dStack:stack pushWithNode:stackNode];
               }];
           } else if (node.action == DNodeActionTypePresent) {
               [self dStackSafe:@selector(dStack:presentWithNode:) exe:^(DStack *stack) {
                   [stack.delegate dStack:stack presentWithNode:stackNode];
               }];
           }
       }
    } else {
        // 来自Native的Node，并且是需要打开Flutter页面的，发消息至flutter，打开页面
        // 如果是DNodePageTypeNative 的话直接就打开了
       if (node.pageType == DNodePageTypeFlutter) {
           [self sendMessageToFlutterWithFlutterNodes:@[node]
                                                 node:node];
       }
    }
}

/// 关闭一个页面
/// @param node 关闭指令
/// @param nodeList 待关闭node列表
+ (void)closePageWithNode:(DNode *)node willRemovedList:(nullable NSArray<DNode *> *)nodeList
{
    if (node.action == DNodeActionTypeUnknow) {return;}
    DNode *targetNode = nodeList.firstObject;
    if (!targetNode) { return;}
    
    DNode *preNode = [DNodeManager sharedInstance].preNode;
    DNode *currentNode = [DNodeManager sharedInstance].currentNode;
    
    if (!currentNode) { return;}
    if (currentNode.pageType == DNodePageTypeFlutter) {
        switch (preNode.pageType) {
            case DNodePageTypeFlutter:
            {
                // 前一个页面是Flutter
                if (node.action == DNodeActionTypeDismiss) {
                    // 当前的flutter页面是被单独的flutterViewController 承载的，要dismiss
                    [self dismissViewController];
                }
                [self sendMessageToFlutterWithFlutterNodes:nodeList
                                                      node:node];
                break;
            }
            case DNodePageTypeNative:
            {
                // 前一个页面是Native, 关闭当前的FlutterViewController，并且发消息告诉flutter返回上一页
                [self closeViewControllerWithNode:node];
                [self sendMessageToFlutterWithFlutterNodes:nodeList
                                                      node:node];
                break;
            }
            case DNodePageTypeUnknow:
            {
                // 前一个节点根节点，并且是Flutter页面
                if ([self rootControllerIsFlutterController]) {
                    // 当前页面还是Flutter，则发消息返回到上一页
                    [self sendMessageToFlutterWithFlutterNodes:nodeList
                                                          node:node];
                } else {
                    // 前面一页不是Flutter页面，如果消息是来自Flutter的则把当前controller关闭掉，
                    // 如果消息是来自native的，则说明是native popViewControllerAnimated触发的操作进入到这里的，所以要去重
                    if (node.fromFlutter) {
                        [self closeViewControllerWithNode:node];
                        [self sendMessageToFlutterWithFlutterNodes:nodeList
                                                              node:node];
                    }
                }
                break;
            }
            default:break;
        }
    } else if (currentNode.pageType == DNodePageTypeNative) {
        DStackLog(@"当前页面是Native，直接返回上一个页面，不需要处理");
    }
}

/// 关闭一组页面
/// @param node 关闭指令
/// @param nodeList 待关闭node列表
+ (void)closePageListWithNode:(DNode *)node willRemovedList:(nullable NSArray<DNode *> *)nodeList
{
    // 拆分出native的节点和flutter的节点
    if (!nodeList.count) { return; }
    // 临界节点 DFlutterViewController
    int boundaryCount = 0;
    
    NSMutableArray <DNode *>*nativeNodes = [[NSMutableArray alloc] init];
    NSMutableArray <DNode *>*flutterNodes = [[NSMutableArray alloc] init];
    for (DNode *obj in nodeList) {
        if (obj.pageType == DNodePageTypeNative) {
            [nativeNodes addObject:obj];
        } else if (obj.pageType == DNodePageTypeFlutter) {
            [flutterNodes addObject:obj];
            if (obj.isFlutterClass) {
                boundaryCount += 1;
            }
        }
    }
    
    if (flutterNodes.count) {
        // flutter的节点信息直接发消息到flutter
        [self sendMessageToFlutterWithFlutterNodes:flutterNodes node:node];
    }
    if (!node.fromFlutter) { return;}
    
    UINavigationController *navigation = [self currentNavigationControllerWithNode:node];
    if (node.action == DNodeActionTypePopToRoot ||
        node.action == DNodeActionTypePopToNativeRoot) {
        [navigation setValue:@(YES) forKey:@"dStackFlutterNodeMessage"];
        [navigation popToRootViewControllerAnimated:YES];
        [navigation setValue:@(NO) forKey:@"dStackFlutterNodeMessage"];
        return;
    }

    NSInteger index = navigation.viewControllers.count - boundaryCount - nativeNodes.count - 1;
    index = index < 0 ? 0 : index;
    UIViewController *target = navigation.viewControllers[index];
    if (target) {
        [navigation setValue:@(YES) forKey:@"dStackFlutterNodeMessage"];
        [navigation popToViewController:target animated:YES];
        [navigation setValue:@(NO) forKey:@"dStackFlutterNodeMessage"];
    } else {
        DStackError(@"%@", @"没有找到需要关闭的controller");
    }
}

/// 发消息至Flutter
/// @param flutterNodes 需要发送至flutter的节点信息
/// @param node 目标节点信息
+ (void)sendMessageToFlutterWithFlutterNodes:(NSArray <DNode *>*)flutterNodes
                                        node:(DNode *)node
{
    if (node.canRemoveNode) {return;}
    NSDictionary *(^wrap)(DNode *) = ^NSDictionary *(DNode *one) {
        return @{
            @"target": one.target,
            @"action": one.actionTypeString,
            @"params": one.params ? node.params : @{},
            @"pageType": one.pageString,
            @"homePage": @(one.isFlutterHomePage),
            @"animated": @(one.animated),
            @"boundary": @(one.boundary),
        };
    };
    NSMutableArray <NSDictionary *>*nodeList = [[NSMutableArray alloc] init];
    NSMutableDictionary <NSString *, id>*params = [[NSMutableDictionary alloc] init];
    if ((node.action == DNodeActionTypePush ||
         node.action == DNodeActionTypePresent ||
         node.action == DNodeActionTypeReplace)) {
        [nodeList addObject:wrap(flutterNodes.firstObject)];
    } else {
        for (DNode *x in flutterNodes) {
            if (!x.isFlutterHomePage) {
                // homePage 页面不能pop，不然会黑屏
                [nodeList addObject:wrap(x)];
            }
        }
    }
    [params setValue:nodeList forKey:@"nodes"];
    [params setValue:node.actionTypeString forKey:@"action"];
    [params setValue:@(node.animated) forKey:@"animated"];
    DStackLog(@"发送【sendActionToFlutter】消息至Flutter\n参数 == %@", params);
    [[DStackPlugin sharedInstance] invokeMethod:DStackMethodChannelSendActionToFlutter arguments:params result:nil];
}

+ (void)closeViewControllerWithNode:(DNode *)node
{
    if (node.action == DNodeActionTypePop) {
        UINavigationController *controller = [self currentNavigationControllerWithNode:node];
        [controller setValue:@(YES) forKey:@"dStackFlutterNodeMessage"];
        [controller popViewControllerAnimated:YES];
        [controller setValue:@(NO) forKey:@"dStackFlutterNodeMessage"];
    } else if (node.action == DNodeActionTypeDismiss) {
        [self dismissViewController];
    }
}

+ (void)dismissViewController
{
    UIViewController *currentVC = self.currentController;
    [currentVC setValue:@(YES) forKey:@"dStackFlutterNodeMessage"];
    [currentVC dismissViewControllerAnimated:YES completion:nil];
    [currentVC setValue:@(NO) forKey:@"dStackFlutterNodeMessage"];
}

+ (DStackNode *)stackNodeFromNode:(DNode *)node
{
    if (!node) { return nil;}
    DStackNode *stackNode = [[DStackNode alloc] init];
    stackNode.route = node.target;
    stackNode.params = node.params;
    stackNode.pageType = node.pageType;
    stackNode.actionType = node.action;
    return stackNode;
}

#pragma mark ============== controller 操作 ===============

/// 前后台切换时，需要检查FlutterEngine里面的flutterViewController是否还存在
/// 如果不存在了而不处理的话会引发crash
+ (void)checkFlutterViewController
{
    __block FlutterViewController *flutterController = nil;
    UINavigationController *navigation = [self currentNavigationControllerWithNode:nil];
    [navigation.viewControllers enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^( UIViewController *obj, NSUInteger idx, BOOL *stop) {
        if ([obj isKindOfClass:FlutterViewController.class]) {
            flutterController = (FlutterViewController *)obj;
            *stop = YES;
        }
    }];
    
    if (flutterController) {
        DStack *stack = [DStack sharedInstance];
        if (!stack.engine.viewController) {
            stack.engine.viewController = flutterController;
        } else {
            if (![navigation.viewControllers containsObject:stack.engine.viewController]) {
                stack.engine.viewController = flutterController;
            }
        }
    }
}

/// rootVC是不是FlutterController
+ (BOOL)rootControllerIsFlutterController
{
    UIViewController *rootVC = self.rootController;
    if ([rootVC isKindOfClass:FlutterViewController.class]) {
        return YES;
    } else {
        if ([rootVC isKindOfClass:UINavigationController.class]) {
            UIViewController *rootController = [[(UINavigationController *)rootVC viewControllers] firstObject];
            if ([rootController isKindOfClass:FlutterViewController.class]) {
                return YES;
            } else if ([rootController isKindOfClass:UITabBarController.class]) {
                return [self _isFlutterControllerWithController:rootVC];
            }
        } else if ([rootVC isKindOfClass:UITabBarController.class]) {
            return [self _isFlutterControllerWithController:rootVC];
        }
    }
    return NO;
}

+ (BOOL)_isFlutterControllerWithController:(UIViewController *)rootVC
{
    UITabBarController *tabVC = (UITabBarController *)rootVC;
    UIViewController *selectedVC = [tabVC selectedViewController];
    if ([selectedVC isKindOfClass:UINavigationController.class]) {
        UIViewController *rootController = [[(UINavigationController *)selectedVC viewControllers] firstObject];
        if ([rootController isKindOfClass:FlutterViewController.class]) {
            return YES;
        }
    } else if ([selectedVC isKindOfClass:FlutterViewController.class]) {
        return YES;
    }
    return NO;
}

+ (UINavigationController *)currentNavigationControllerWithNode:(DNode *)node
{
    __block UINavigationController *navigationController = nil;
    [self dStackSafe:@selector(dStack:navigationControllerForNode:) exe:^(DStack *stack) {
        DStackNode *stackNode = [self stackNodeFromNode:node];
        navigationController = [stack.delegate dStack:stack navigationControllerForNode:stackNode];
    }];
    if (!navigationController) {
        DStackError(@"当前的NavigationController为空");
    }
    return navigationController;
}

+ (UIViewController *)currentController
{
    UIViewController *controller = nil;
    DStack *stack = [DStack sharedInstance];
    if (stack.delegate && [stack.delegate respondsToSelector:@selector(visibleControllerForCurrentWindow)]) {
        controller = [stack.delegate visibleControllerForCurrentWindow];
    };
    NSAssert(controller, @"visibleControllerForCurrentWindow返回了空的controller");
    return controller;
}

+ (UIViewController *)rootController
{
    UIViewController *rootVC = [UIApplication sharedApplication].delegate.window.rootViewController;
    if (!rootVC) {
        rootVC = [[[UIApplication sharedApplication] keyWindow] rootViewController];
    }
    return rootVC;
}

+ (void)dStackSafe:(SEL)sel exe:(void(^)(DStack *stack))exe
{
    DStack *stack = [DStack sharedInstance];
    if (stack.delegate && [stack.delegate respondsToSelector:sel]) {
        if (exe) {
            exe(stack);
        }
    } else {
        DStackError(@"请实现%@代理", NSStringFromSelector(sel));
    }
}

@end
