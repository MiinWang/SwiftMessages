//
//  MessagePresenter.swift
//  SwiftMessages
//
//  Created by Timothy Moose on 7/30/16.
//  Copyright © 2016 SwiftKick Mobile LLC. All rights reserved.
//

import UIKit

protocol PresenterDelegate: AnimationDelegate {
    func hide(presenter: Presenter)
}

class Presenter: NSObject {

    enum PresentationContext {
        case viewController(_: Weak<UIViewController>)
        case view(_: Weak<UIView>)
        
        func viewControllerValue() -> UIViewController? {
            switch self {
            case .viewController(let weak):
                return weak.value
            case .view:
                return nil
            }
        }
        
        func viewValue() -> UIView? {
            switch self {
            case .viewController(let weak):
                return weak.value?.view
            case .view(let weak):
                return weak.value
            }
        }
    }
    
    let view: UIView
    let config: SwiftMessages.Config
    weak var delegate: PresenterDelegate?
    let maskingView = MaskingView()
    var presentationContext = PresentationContext.viewController(Weak<UIViewController>(value: nil))
    let animator: Animator

    init(config: SwiftMessages.Config, view: UIView, delegate: PresenterDelegate) {
        self.config = config
        self.view = view
        self.delegate = delegate
        self.animator = Presenter.animator(forPresentationStyle: config.presentationStyle, delegate: delegate)
        super.init()
        maskingView.clipsToBounds = true
        id = (view as? Identifiable)?.id
    }

    private static func animator(forPresentationStyle style: SwiftMessages.PresentationStyle, delegate: AnimationDelegate) -> Animator {
        switch style {
        case .top:
            return TopBottomAnimation(style: .top, delegate: delegate)
        case .bottom:
            return TopBottomAnimation(style: .bottom, delegate: delegate)
        case .center:
            return CenterAnimation(delegate: delegate)
        case .custom(let animator):
            animator.delegate = delegate
            return animator
        }
    }

    var id: String?
    
    var pauseDuration: TimeInterval? {
        let duration: TimeInterval?
        switch self.config.duration {
        case .automatic:
            duration = 2
        case .seconds(let seconds):
            duration = seconds
        case .forever, .indefinite:
            duration = nil
        }
        return duration
    }

    var showDate: Date?

    private var interactivelyHidden = false;

    var delayShow: TimeInterval? {
        if case .indefinite(let opts) = config.duration { return opts.delay }
        return nil
    }

    /// Returns the required delay for hiding based on time shown
    var delayHide: TimeInterval? {
        if interactivelyHidden { return 0 }
        if case .indefinite(let opts) = config.duration, let showDate = showDate {
            let timeIntervalShown = -showDate.timeIntervalSinceNow
            return max(0, opts.minimum - timeIntervalShown)
        }
        return nil
    }

    /*
     MARK: - Showing and hiding
     */

    func show(completion: @escaping AnimationCompletion) throws {
        try presentationContext = getPresentationContext()
        install()
        self.config.eventListeners.forEach { $0(.willShow) }
        showAnimation() { completed in
            completion(completed)
            if completed {
                if self.config.dimMode.modal {
                    self.showAccessibilityFocus()
                } else {
                    self.showAccessibilityAnnouncement()
                }
                self.config.eventListeners.forEach { $0(.didShow) }
            }
        }
    }

    private func showAnimation(completion: @escaping AnimationCompletion) {

        func dim(_ color: UIColor) {
            self.maskingView.backgroundColor = UIColor.clear
            UIView.animate(withDuration: 0.2, animations: {
                self.maskingView.backgroundColor = color
            })
        }

        func blur(style: UIBlurEffectStyle, alpha: CGFloat) {
            let blurView = UIVisualEffectView(effect: nil)
            blurView.alpha = alpha
            maskingView.backgroundView = blurView
            UIView.animate(withDuration: 0.3) {
                blurView.effect = UIBlurEffect(style: style)
            }
        }

        let context = animationContext()
        animator.show(context: context) { (completed) in
            completion(completed)
        }
        switch config.dimMode {
        case .none:
            break
        case .gray:
            dim(UIColor(white: 0, alpha: 0.3))
        case .color(let color, _):
            dim(color)
        case .blur(let style, let alpha, _):
            blur(style: style, alpha: alpha)
        }
    }

    private func showAccessibilityAnnouncement() {
        guard let accessibleMessage = view as? AccessibleMessage,
            let message = accessibleMessage.accessibilityMessage else { return }
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message)
    }

    private func showAccessibilityFocus() {
        guard let accessibleMessage = view as? AccessibleMessage,
            let focus = accessibleMessage.accessibilityElement ?? accessibleMessage.additonalAccessibilityElements?.first else { return }
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, focus)
    }

    var isHiding = false

    func hide(completion: @escaping AnimationCompletion) {
        isHiding = true
        self.config.eventListeners.forEach { $0(.willHide) }
        let context = animationContext()
        animator.hide(context: context) { (completed) in
            if let viewController = self.presentationContext.viewControllerValue() as? WindowViewController {
                viewController.uninstall()
            }
            self.maskingView.removeFromSuperview()
            completion(true)
            self.config.eventListeners.forEach { $0(.didHide) }
        }

        func undim() {
            UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState, animations: {
                self.maskingView.backgroundColor = UIColor.clear
            }, completion: nil)
        }

        func unblur() {
            guard let view = maskingView.backgroundView as? UIVisualEffectView else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState, animations: { 
                view.effect = nil
            }, completion: nil)
        }
        
        switch config.dimMode {
        case .none:
            break
        case .gray:
            undim()
        case .color:
            undim()
        case .blur:
            unblur()
        }
    }

    private func animationContext() -> AnimationContext {
        return AnimationContext(messageView: view, containerView: maskingView, behindStatusBar: interferesWithStatusBar, interactiveHide: config.interactiveHide)
    }

    private var interferesWithStatusBar: Bool {
        guard let window = maskingView.window else { return false }
        if UIApplication.shared.isStatusBarHidden { return false }
        if let vc = presentationContext.viewControllerValue() as? WindowViewController, vc.windowLevel != UIWindowLevelNormal { return false }
        if let vc = presentationContext.viewControllerValue() as? UINavigationController, vc.sm_isVisible(view: vc.navigationBar) { return false }
        let statusBarFrame = UIApplication.shared.statusBarFrame
        let statusBarWindowFrame = window.convert(statusBarFrame, from: nil)
        let statusBarViewFrame = maskingView.convert(statusBarWindowFrame, from: nil)
        return statusBarViewFrame.intersects(maskingView.bounds)
    }

    private func getPresentationContext() throws -> PresentationContext {

        func newWindowViewController(_ windowLevel: UIWindowLevel) -> UIViewController {
            let viewController = WindowViewController(windowLevel: windowLevel, config: config)
            return viewController
        }

        switch config.presentationContext {
        case .automatic:
            if let rootViewController = UIApplication.shared.keyWindow?.rootViewController {
                let viewController = rootViewController.sm_selectPresentationContextTopDown(config)
                return .viewController(Weak(value: viewController))
            } else {
                throw SwiftMessagesError.noRootViewController
            }
        case .window(let level):
            let viewController = newWindowViewController(level)
            return .viewController(Weak(value: viewController))
        case .viewController(let viewController):
            let viewController = viewController.sm_selectPresentationContextBottomUp(config)
            return .viewController(Weak(value: viewController))
        case .view(let view):
            return .view(Weak(value: view))
        }
    }

    /*
     MARK: - Installation
     */

    func install() {

        func topLayoutConstraint(view: UIView, containerView: UIView, viewController: UIViewController?) -> NSLayoutConstraint {
            if case .top = config.presentationStyle, let nav = viewController as? UINavigationController, nav.sm_isVisible(view: nav.navigationBar) {
                return NSLayoutConstraint(item: view, attribute: .top, relatedBy: .equal, toItem: nav.navigationBar, attribute: .bottom, multiplier: 1.00, constant: 0.0)
            }
            return NSLayoutConstraint(item: view, attribute: .top, relatedBy: .equal, toItem: containerView, attribute: .top, multiplier: 1.00, constant: 0.0)
        }

        func bottomLayoutConstraint(view: UIView, containerView: UIView, viewController: UIViewController?) -> NSLayoutConstraint {
            if case .bottom = config.presentationStyle, let tab = viewController as? UITabBarController, tab.sm_isVisible(view: tab.tabBar) {
                return NSLayoutConstraint(item: view, attribute: .bottom, relatedBy: .equal, toItem: tab.tabBar, attribute: .top, multiplier: 1.00, constant: 0.0)
            }
            return NSLayoutConstraint(item: view, attribute: .bottom, relatedBy: .equal, toItem: containerView, attribute: .bottom, multiplier: 1.00, constant: 0.0)
        }

        func installMaskingView(containerView: UIView) {
            maskingView.translatesAutoresizingMaskIntoConstraints = false
            if let nav = presentationContext.viewControllerValue() as? UINavigationController {
                containerView.insertSubview(maskingView, belowSubview: nav.navigationBar)
            } else if let tab = presentationContext.viewControllerValue() as? UITabBarController {
                containerView.insertSubview(maskingView, belowSubview: tab.tabBar)
            } else {
                containerView.addSubview(maskingView)
            }
            let leading = NSLayoutConstraint(item: maskingView, attribute: .leading, relatedBy: .equal, toItem: containerView, attribute: .leading, multiplier: 1.00, constant: 0.0)
            let trailing = NSLayoutConstraint(item: maskingView, attribute: .trailing, relatedBy: .equal, toItem: containerView, attribute: .trailing, multiplier: 1.00, constant: 0.0)
            let top = topLayoutConstraint(view: maskingView, containerView: containerView, viewController: presentationContext.viewControllerValue())
            let bottom = bottomLayoutConstraint(view: maskingView, containerView: containerView, viewController: presentationContext.viewControllerValue())
            containerView.addConstraints([top, leading, bottom, trailing])
            // Update the container view's layout in order to know the masking view's frame
            containerView.layoutIfNeeded()
        }

        func installInteractive() {
            guard config.dimMode.modal else { return }
            if config.dimMode.interactive {
                maskingView.tappedHander = { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.interactivelyHidden = true
                    strongSelf.delegate?.hide(presenter: strongSelf)
                }
            } else {
                // There's no action to take, but the presence of
                // a tap handler prevents interaction with underlying views.
                maskingView.tappedHander = { }
            }
        }

        func installAccessibility() {
            var elements: [NSObject] = []
            if let accessibleMessage = view as? AccessibleMessage {
                if let message = accessibleMessage.accessibilityMessage {
                    let element = accessibleMessage.accessibilityElement ?? view
                    element.isAccessibilityElement = true
                    if element.accessibilityLabel == nil {
                        element.accessibilityLabel = message
                    }
                    elements.append(element)
                }
                if let additional = accessibleMessage.additonalAccessibilityElements {
                    elements += additional
                }
            }
            if config.dimMode.interactive {
                let dismissView = UIView(frame: maskingView.bounds)
                dismissView.translatesAutoresizingMaskIntoConstraints = true
                dismissView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                maskingView.addSubview(dismissView)
                maskingView.sendSubview(toBack: dismissView)
                dismissView.isUserInteractionEnabled = false
                dismissView.isAccessibilityElement = true
                dismissView.accessibilityLabel = config.dimModeAccessibilityLabel
                dismissView.accessibilityTraits = UIAccessibilityTraitButton
                elements.append(dismissView)
            }
            if config.dimMode.modal {
                maskingView.accessibilityViewIsModal = true
            }
            maskingView.accessibleElements = elements
        }

        guard let containerView = presentationContext.viewValue() else { return }
        if let windowViewController = presentationContext.viewControllerValue() as? WindowViewController {
            windowViewController.install(becomeKey: becomeKeyWindow)
        }
        installMaskingView(containerView: containerView)
        installInteractive()
        installAccessibility()
    }

    private var becomeKeyWindow: Bool {
        if config.becomeKeyWindow == .some(true) { return true }
        switch config.dimMode {
        case .gray, .color, .blur:
            // Should become key window in modal presentation style
            // for proper VoiceOver handling.
            return true
        case .none:
            return false
        }
    }
}


