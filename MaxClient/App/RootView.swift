import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: Session
    @State private var hasBootstrapped = false

    var body: some View {
        Group {
            switch session.phase {
            case .launching:
                SplashView()
            case .unauthenticated:
                PhoneAuthView()
            case .authenticated:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.phase)
        .task {
            guard !hasBootstrapped else { return }
            hasBootstrapped = true
            await session.bootstrap()
        }
    }
}

struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.brandGradientStart, Theme.brandGradientEnd],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(pulse ? 1.06 : 0.94)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

                Text("MAX")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                ProgressView()
                    .tint(.white)
                    .padding(.top, 8)
            }
            .onAppear { pulse = true }
        }
    }
}
