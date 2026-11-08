import AppKit
import SwiftUI
import DistillerCommunity

/// GitHub's mark, from Octicons `mark-github-16` (MIT licence, Copyright (c) GitHub Inc.),
/// converted to path calls so it draws the same on every macOS version.
struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * scale, y: rect.midY - 8 * scale)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        path.move(to: p(6.766, 11.328))
        path.addCurve(to: p(3.25, 7.672), control1: p(4.703, 11.078), control2: p(3.25, 9.594))
        path.addCurve(to: p(4, 5.484), control1: p(3.25, 6.891), control2: p(3.531, 6.047))
        path.addCurve(to: p(4.063, 3.422), control1: p(3.797, 4.969), control2: p(3.828, 3.875))
        path.addCurve(to: p(6.031, 4.125), control1: p(4.688, 3.344), control2: p(5.531, 3.672))
        path.addCurve(to: p(8.016, 3.844), control1: p(6.625, 3.938), control2: p(7.25, 3.844))
        path.addCurve(to: p(9.969, 4.109), control1: p(8.781, 3.844), control2: p(9.406, 3.938))
        path.addCurve(to: p(11.938, 3.422), control1: p(10.453, 3.672), control2: p(11.313, 3.344))
        path.addCurve(to: p(11.984, 5.469), control1: p(12.156, 3.844), control2: p(12.188, 4.937))
        path.addCurve(to: p(12.75, 7.672), control1: p(12.484, 6.062), control2: p(12.75, 6.859))
        path.addCurve(to: p(9.203, 11.312), control1: p(12.75, 9.594), control2: p(11.297, 11.047))
        path.addCurve(to: p(10.093, 13.266), control1: p(9.734, 11.656), control2: p(10.093, 12.406))
        path.addLine(to: p(10.093, 14.891))
        path.addCurve(to: p(10.953, 15.438), control1: p(10.093, 15.359), control2: p(10.484, 15.625))
        path.addCurve(to: p(16, 8.03), control1: p(13.781, 14.359), control2: p(16, 11.53))
        path.addCurve(to: p(7.984, 0), control1: p(16, 3.61), control2: p(12.406, 0))
        path.addCurve(to: p(0, 8.031), control1: p(3.563, 0), control2: p(0, 3.61))
        path.addCurve(to: p(5.172, 15.453), control1: p(-0.009, 11.347), control2: p(2.058, 14.314))
        path.addCurve(to: p(6, 14.906), control1: p(5.594, 15.609), control2: p(6, 15.328))
        path.addLine(to: p(6, 13.656))
        path.addCurve(to: p(5.25, 13.812), control1: p(5.781, 13.75), control2: p(5.5, 13.812))
        path.addCurve(to: p(3.172, 12.203), control1: p(4.219, 13.812), control2: p(3.61, 13.25))
        path.addCurve(to: p(2.453, 11.484), control1: p(3, 11.781), control2: p(2.812, 11.531))
        path.addCurve(to: p(2.203, 11.297), control1: p(2.266, 11.469), control2: p(2.203, 11.391))
        path.addCurve(to: p(2.828, 10.969), control1: p(2.203, 11.109), control2: p(2.516, 10.969))
        path.addCurve(to: p(4.078, 11.829), control1: p(3.281, 10.969), control2: p(3.672, 11.25))
        path.addCurve(to: p(5.109, 12.484), control1: p(4.391, 12.281), control2: p(4.718, 12.484))
        path.addCurve(to: p(6.109, 11.984), control1: p(5.5, 12.484), control2: p(5.75, 12.344))
        path.addCurve(to: p(6.766, 11.328), control1: p(6.375, 11.719), control2: p(6.579, 11.484))
        path.closeSubpath()
        return path
    }
}

/// The signed-in account's picture in a circle, or the GitHub mark while it loads or when there isn't one.
struct GitHubAvatar: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat

    var body: some View {
        if let image = model.roundGitHubAvatar(points: size) {
            Image(nsImage: image)
        } else {
            GitHubMark().fill(.secondary).frame(width: size, height: size)
        }
    }
}

/// Signing in with GitHub's device flow: a button, then the code to enter on github.com.
struct GitHubSignInPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let code = model.signInCode {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter this code on GitHub:")
                Text(code.userCode)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                HStack {
                    Button("Copy Code and Open GitHub") { model.copyCodeAndOpenGitHub(code) }
                        .buttonStyle(.borderedProminent)
                    Button("Cancel") { model.cancelSignIn() }
                }
                Text("Waiting for you to approve Distiller on GitHub…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button {
                model.signInToGitHub()
            } label: {
                Label {
                    Text("Sign In with GitHub")
                } icon: {
                    GitHubMark().frame(width: 14, height: 14)
                }
            }
        }
    }
}

/// The toolbar's account button: the GitHub mark until the player signs in, then their picture.
struct GitHubToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingSignIn = false

    var body: some View {
        if let user = model.githubUser {
            Menu {
                Text("Signed in to GitHub as \(user.login)")
                Button("Open Profile on GitHub") { model.openGitHubProfile() }
                Divider()
                Button("Sign Out") { model.signOutOfGitHub() }
            } label: {
                GitHubAvatar(size: 16)
            }
            .menuIndicator(.hidden)
            .help("Signed in to GitHub as \(user.login)")
        } else {
            Button {
                isShowingSignIn = true
                if model.signInCode == nil { model.signInToGitHub() }
            } label: {
                Label {
                    Text("Sign In with GitHub")
                } icon: {
                    GitHubMark().frame(width: 16, height: 16)
                }
            }
            .help("Sign in with GitHub to submit recipes to the community")
            .popover(isPresented: $isShowingSignIn, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign in with GitHub").font(.headline)
                    Text("Signing in lets Distiller submit your recipes to the community catalogue as pull requests. Browsing and installing recipes work without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    GitHubSignInPanel()
                }
                .padding(16)
                .frame(width: 320)
            }
            .onChange(of: model.githubUser) { if model.githubUser != nil { isShowingSignIn = false } }
        }
    }
}

extension NSImage {
    /// GitHub's mark as a template image, for places that need an `Image` rather than a
    /// shape (the Settings tab).
    @MainActor static var gitHubMarkTemplate: NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(GitHubMark().path(in: rect.insetBy(dx: 1, dy: 1)).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The GitHub account in Settings.
struct GitHubSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let user = model.githubUser {
                HStack(spacing: 10) {
                    GitHubAvatar(size: 32)
                    VStack(alignment: .leading) {
                        Text(user.name ?? user.login)
                        if user.name != nil {
                            Text(user.login).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Open Profile") { model.openGitHubProfile() }
                    Button("Sign Out") { model.signOutOfGitHub() }
                }
            } else {
                GitHubSignInPanel()
            }
        } header: {
            Text("GitHub")
        } footer: {
            Text("Signing in lets Distiller submit recipes to \(model.repository.fullName) as pull requests: from a copy of the repository on your account, or from a branch in the repository itself if you maintain it. Distiller asks for access to public repositories, and keeps the token in your keychain. Browsing and installing community recipes don't need an account.")
        }
    }
}
