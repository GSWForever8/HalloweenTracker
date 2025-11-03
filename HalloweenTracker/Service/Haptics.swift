//
//  Haptics.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/27/25.
//

import UIKit

enum Haptics {
    /// A quick “scare” pattern: thud → brief pause → warning buzz
    static func scare() {
        let thud = UIImpactFeedbackGenerator(style: .heavy)
        thud.prepare()
        thud.impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let warn = UINotificationFeedbackGenerator()
            warn.prepare()
            warn.notificationOccurred(.warning)
        }
    }

    /// Simple single thud if you want it subtler
    static func thud() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
