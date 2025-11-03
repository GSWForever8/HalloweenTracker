//
//  Background.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/19/25.
//

import SwiftUI

struct BackgroundView : View{
    var body: some View{
        ZStack(alignment: .top) {
                Color.black.edgesIgnoringSafeArea(.all)

                LinearGradient(gradient: Gradient(colors: [Color.orange.opacity(0.8), Color.clear]), startPoint: .top, endPoint: .bottom)
                    .frame(height: 200)
                    .edgesIgnoringSafeArea(.all)
            }
    }
}
#Preview {
    BackgroundView()
}
