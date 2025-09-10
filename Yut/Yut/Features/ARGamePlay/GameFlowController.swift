//
//  GameFlowController.swift
//  Yut
//
//  Created by soyeonsoo on 9/10/25.
//

import Foundation
import Combine

final class GameFlowController {
    private let state: ARState
    private let pieceManager: PieceManager
    private let boardManager: BoardManager
    private let yutManager: YutManager

    init(state: ARState,
         pieceManager: PieceManager,
         boardManager: BoardManager,
         yutManager: YutManager) {
        self.state = state
        self.pieceManager = pieceManager
        self.boardManager = boardManager
        self.yutManager = yutManager
    }

    // MARK: - 1. 새 게임 준비
    func setupNewGame(with players: [PlayerModel]) {
        Task { @MainActor in
            state.gameManager.startGame(with: players)
            pieceManager.boardAnchor = boardManager.yutBoardAnchor
            state.gamePhase = .readyToThrow
        }
    }

    // MARK: - 2. 새 말 놓기
    func showDestinationsForNewPiece() {
        let gameManager = state.gameManager
        guard let newPiece = gameManager.currentPlayer.pieces.first(where: { $0.position == "_6_6" }),
              let yutResult = gameManager.yutResult else { return }

        let destinations = gameManager.routeOptions(for: newPiece,
                                                    yutResult: yutResult,
                                                    currentRouteIndex: newPiece.routeIndex)

        if !destinations.isEmpty {
            let destinationNames = destinations.map { $0.destinationID }
            pieceManager.highlightTiles(named: destinationNames)

            state.selectedPieces = [newPiece]
            state.availableDestinations = destinationNames
            DispatchQueue.main.async {
                self.state.gamePhase = .selectingDestination
            }
        }
    }

    // MARK: - 3. 윷 결과 완료 후 → 말 선택
    func yutThrowCompleted(with result: YutResult) {
        state.yutResult = result
        state.gameManager.yutResult = result
        pieceManager.clearAllHighlights()

        DispatchQueue.main.async {
            self.state.gamePhase = .showingYutResult
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for yutModel in self.yutManager.thrownYuts {
                    yutModel.entity.parent?.removeFromParent()
                }
                self.yutManager.thrownYuts.removeAll()
                self.state.gamePhase = .selectingPieceToMove
            }
        }
    }

    // MARK: - 4. 턴 종료
    func endTurn() {
        let gameManager = state.gameManager

        if gameManager.yutResult?.isExtraTurn == false {
            gameManager.nextTurn()
            state.gamePhase = .readyToThrow
        } else {
            state.yutResult = nil
            DispatchQueue.main.async {
                self.state.gamePhase = .showingYutResult
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.state.gamePhase = .readyToThrow
                }
            }
        }
    }

    // MARK: - 5. 말 이동 요청 처리
    func processMoveRequest(pieces: [PieceModel], to destination: String) {
        let piecesAtDestination = state.gameManager.cellStates[destination] ?? []

        if piecesAtDestination.isEmpty {
            executeMove(pieces: pieces, to: destination, didCarry: false)
        } else if let firstPiece = piecesAtDestination.first,
                  let movingPieceOwner = pieces.first?.owner,
                  firstPiece.owner.id != movingPieceOwner.id {
            executeMove(pieces: pieces, to: destination, didCarry: false)
        } else {
            state.pendingMove = (pieces, destination)
            state.gamePhase = .promptingForCarry
        }
    }

    func resolveMove(carry: Bool) {
        guard let pendingMove = state.pendingMove else { return }
        executeMove(pieces: pendingMove.pieces,
                    to: pendingMove.destination,
                    didCarry: carry)
    }

    // MARK: - 6. 실제 말 이동
    private func executeMove(pieces: [PieceModel], to destination: String, didCarry: Bool) {
        guard let representativePiece = pieces.first else { return }

        var finalResult: GameResult?

        // --- 논리 처리 ---
        for (index, piece) in pieces.enumerated() {
            let isFirstPiece = (index == 0)
            let result = state.gameManager.applyMoveResult(
                piece: piece,
                to: destination,
                userChooseToCarry: isFirstPiece ? didCarry : true
            )
            if isFirstPiece {
                finalResult = result
            }
        }

        guard let finalResult = finalResult else { return }

        // --- 시각 처리 ---
        if finalResult.didCapture {
            pieceManager.resetPieces(finalResult.capturedPieces)
        }

        for piece in pieces {
            if piece.entity.parent == nil {
                pieceManager.placePieceOnBoard(piece: piece, on: destination)
            } else {
                pieceManager.movePiece(piece: piece.entity, to: destination)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.pieceManager.arrangePiecesOnTile(destination, didCarry: finalResult.didCarry)
        }

        // --- 후처리 ---
        pieceManager.clearAllHighlights()
        state.selectedPieces = nil
        state.availableDestinations = []
        state.pendingMove = nil

        if finalResult.didCapture {
            state.gamePhase = .readyToThrow
        } else {
            endTurn()
        }
    }
}
