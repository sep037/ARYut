//
//  TokenManager.swift
//  Yut
//
//  Created by yunsly on 7/27/25.
//

import Foundation
import RealityKit
import ARKit

final class PieceManager {
    
    var boardAnchor: AnchorEntity // 윷판 앵커
    let gameManager: GameManager
    
    var pieceEntities: [Entity] = []
    
    private var originalMaterials: [ModelEntity: RealityFoundation.Material] = [:]
    static let pieceScale: SIMD3<Float> = [0.3, 10.0, 0.3]
    
    init(boardAnchor: AnchorEntity, gameManager: GameManager) {
        self.boardAnchor = boardAnchor
        self.gameManager = gameManager
    }
    
    // MARK: - Pieces Logic
    
    // 판 밖에 있던 말을 처음으로 AR 씬에 추가하는 함수
    func placePieceOnBoard(piece: PieceModel, on tileName: String) {
        guard let destinationTile = boardAnchor.findEntity(named: tileName) else {
            print("❌ [PieceManager] placePieceOnBoard: 목적지 \(tileName) 타일을 찾을 수 없습니다.")
            return
        }
        
        let pieceEntity = piece.entity
        // 말이 다른 곳에 속해 있었다면, 안전하게 부모로부터 분리합니다.
        if pieceEntity.parent != nil {
            pieceEntity.removeFromParent()
        }
        
        pieceEntity.name = piece.id.uuidString
        pieceEntity.generateCollisionShapes(recursive: true)
        
        // 이 함수에서는 위치와 스케일을 초기 고정값으로 설정합니다.
        pieceEntity.scale = PieceManager.pieceScale
        pieceEntity.position = [0, 0.1, 0] // 타일 바닥에서 살짝 띄워서 배치
        
        destinationTile.addChild(pieceEntity)
        print("✅ [PieceManager] \(piece.entity.name)을 \(tileName)에 처음으로 배치했습니다.")
    }
    
    func movePiece(piece: Entity, to tileName: String) {
        guard let destinationTile = boardAnchor.findEntity(named: tileName) else {
            print("❌ [PieceManager] movePiece: 목적지 \(tileName) 타일을 찾을 수 없습니다.")
            return
        }
        
        var destinationPosition = destinationTile.position(relativeTo: nil)
        destinationPosition.y += 0.02
        
        var transform = Transform(matrix: piece.transformMatrix(relativeTo: nil))
        transform.translation = destinationPosition
        
        piece.move(
            to: transform,
            relativeTo: nil,
            duration: 0.5,
            timingFunction: .easeInOut
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            piece.setParent(destinationTile)
            piece.setPosition([0, 0.02, 0], relativeTo: destinationTile)
            
            print("✅ \(piece.name) 이동 완료 → \(tileName)")
        }
    }
    
    // 잡힌 말들을 판에서 제거하는 시각적 처리를 합니다.
    func resetPieces(_ pieces: [PieceModel]) {
        for piece in pieces {
            print("💥 [PieceManager] \(piece.entity.name) 말을 잡아서 판에서 제거합니다.")
            piece.entity.removeFromParent()
        }
    }
    
    // 업기/따로가기 시각 효과를 위해 타일 위의 말들을 재배치합니다.
    func arrangePiecesOnTile(_ tileName: String, didCarry: Bool) {
        guard let tileEntity = boardAnchor.findEntity(named: tileName) else { return }
        
        // GameManager의 cellStates를 기준으로 해당 타일에 있는 모든 말을 논리적으로 찾아옵니다.
        let piecesOnTile = gameManager.cellStates[tileName] ?? []
        print("🔄 [PieceManager] \(tileName) 위의 말 \(piecesOnTile.count)개를 재배치합니다. (업기: \(didCarry))")
        
        if didCarry {
            // 업었을 경우: 말들을 수직으로 쌓습니다.
            for (index, piece) in piecesOnTile.enumerated() {
                // ⭐️ 보기 좋은 높이로 간격 조정
                let yOffset = Float(index) * 0.7
                print("    - 인덱스 \(index): 말 \(piece.id.uuidString)에 yOffset \(yOffset) 적용")
                
                // ⭐️ 수정된 부분: .move 함수를 사용하여 기준(relativeTo)을 명확히 하고, 애니메이션으로 재배치합니다.
                let newTransform = Transform(
                    scale: PieceManager.pieceScale,
                    rotation: piece.entity.orientation,
                    translation: [0, yOffset, 0]
                )
                piece.entity.move(to: newTransform, relativeTo: tileEntity, duration: 0.25)
            }
        } else {
            // 따로 가는 경우: 말들을 수평으로 나란히 놓습니다.
            let spacing: Float = 0.2
            let count = Float(piecesOnTile.count)
            let initialOffset = -spacing * (count - 1) / 2.0
            
            for (index, piece) in piecesOnTile.enumerated() {
                let xOffset = initialOffset + (Float(index) * spacing)
                
                // ⭐️ 수정된 부분: .move 함수를 사용하여 기준(relativeTo)을 명확히 하고, 애니메이션으로 재배치합니다.
                let newTransform = Transform(
                    scale: PieceManager.pieceScale,
                    rotation: piece.entity.orientation,
                    translation: [xOffset, 0, 0]
                )
                piece.entity.move(to: newTransform, relativeTo: tileEntity, duration: 0.25)
            }
        }
    }
    
    // MARK: - Highlighting
    
    // 하이라이트할 Tile Entity 반환
    func highlightTiles(named tileNames: [String]) {
        guard let boardEntity = boardAnchor.children.first else {
            print("❌ 윷판 엔티티 없음")
            return
        }
        
        clearAllHighlights() // 이전에 있던 모든 하이라이트 제거
        
        for name in tileNames {
            guard let tile = boardEntity.findEntity(named: name) as? ModelEntity else { continue }
            applyHighlight(to: tile)
        }
    }
    
    // 하이라이트할 말 Entity 반환
    func highlightMovablePieces(_ pieces: [PieceModel]) {
        clearAllHighlights() // 이전에 있던 모든 하이라이트 제거
        
        for piece in pieces {
            guard let pieceEntity = piece.entity as? ModelEntity else { continue }
            applyHighlight(to: pieceEntity)
        }
    }
    
    // 인자로 받은 엔티티의 하이라이트 적용
    private func applyHighlight(to entity: ModelEntity) {
        guard let model = entity.model else { return }
        
        // 원래 머티리얼을 딕셔너리에 저장
        if let material = model.materials.first {
            originalMaterials[entity] = material
        }
        
        // 하이라이트 머티리얼 생성 및 적용
        var highlightMaterial = UnlitMaterial()
        highlightMaterial.color = .init(tint: .yellow.withAlphaComponent(0.8))
        
        var newModel = model
        newModel.materials = [highlightMaterial]
        entity.model = newModel
    }
    
    // 모든 하이라이트를 원래대로 되돌리는 함수
    func clearAllHighlights() {
        for (entity, originalMaterial) in originalMaterials {
            entity.model?.materials = [originalMaterial]
        }
        originalMaterials.removeAll()
    }
}
