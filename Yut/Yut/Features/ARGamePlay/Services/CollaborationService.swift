//
//  CollaborationService.swift
//  Yut
//
//  Created by soyeonsoo on 9/10/25.
//

import Foundation
import MultipeerConnectivity

final class CollaborationService {
    private let mpc = MPCManager.shared

    var isHost: Bool { mpc.isHost }

    /// ARKit이 준 collaborationData를 모두 피어에게 중계
    func relayCollaborationData(_ data: Data) {
        guard let session = mpc.session else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// 게임 상태 동기화
    func sendGameState(_ state: GameStateData) {
        guard let session = mpc.session,
              let data = try? JSONEncoder().encode(state) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}
