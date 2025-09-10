import ARKit
import Combine
import MultipeerConnectivity
import RealityKit

/// ARView의 이벤트를 처리하고 SwiftUI 상태와 연결해주는 총괄 Coordinator
class ARCoordinator: NSObject, ARSessionDelegate {
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 외부 연결 (의존 객체)
    
    var arView: ARView? {
        didSet {
            gestureHandler.arView = arView
            planeManager.scene = arView?.scene
            bindPlaneArea()
        }
    }
    
    var arState: ARState? {
        didSet {
            if let arState {
                arState.coordinator = self
                actionStreamHandler.subscribe(to: arState)
                
                gameFlow = GameFlowController(
                    state: arState,
                    pieceManager: pieceManager,
                    boardManager: boardManager,
                    yutManager: yutManager
                )
                arState.isCoordinatorReady = true
            }
        }
    }
    
    
    private let collab = CollaborationService()
    
    private var gameFlow: GameFlowController!
    
    
    // MARK: - 서브 매니저
    
    var gestureHandler: GestureHandler!
    var boardManager: BoardManager!
    var planeManager: PlaneManager = PlaneManager()
    var pieceManager: PieceManager!
    var yutManager: YutManager!
    var assetCacheManager: AssetCacheManager!
    var actionStreamHandler: ActionStreamHandler!
        
    override init() {
        super.init()
        self.boardManager = BoardManager(coordinator: self)
        self.pieceManager = PieceManager(coordinator: self)
        self.yutManager = YutManager(coordinator: self)
        self.assetCacheManager = AssetCacheManager()
        self.gestureHandler = GestureHandler(coordinator: self)
        self.actionStreamHandler = ActionStreamHandler(coordinator: self)
    }
    
    private func bindPlaneArea() {
        planeManager
            .recognizedAreaPublisher
            .receive(on: DispatchQueue.main)
            .sink{ [weak self] area in
                guard let self, let arState = self.arState else { return }
                guard area >= arState.recognizedArea else { return }
                arState.recognizedArea = area
                
                if area >= arState.minRequiredArea, arState.gamePhase == .scanningPlanes {
                    arState.gamePhase = .placingBoard
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - ARSessionDelegate (앵커 업데이트 처리)
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for anchor in anchors {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                planeManager.addPlane(for: planeAnchor)
            } else if let name = anchor.name, name == "YutBoardAnchor" {
                boardManager.placeYutBoard(on: anchor)
                
                // Host가 말판을 배치했을 때 다른 피어들과 공유
                if collab.isHost {
                    print("🎯 Host: 말판 앵커 추가됨 - Guest들과 공유 중...")
                    // 앵커가 자동으로 다른 피어들과 공유됨
                }
            }
        }
    }
    
    func session(_ session: ARSession, didReceive anchors: [ARAnchor]) {
        anchors.compactMap { $0 as? ARPlaneAnchor }.forEach {
            planeManager.addPlane(for: $0)
        }

        anchors.filter { ($0.name ?? "") == "YutBoardAnchor" }.forEach {
            boardManager.placeYutBoard(on: $0)
            if collab.isHost { /* ... */ }
        }
    }
    
    // 협업 데이터 수신 및 전송
    func session(_ session: ARSession, didReceive collaborationData: Data) {
        // MPC를 통해 협업 데이터 전송
        collab.relayCollaborationData(collaborationData)
    }
    
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        anchors.compactMap { $0 as? ARPlaneAnchor }.forEach {
            planeManager.updatePlane(for: $0)
        }
    }
    
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        anchors.compactMap{ $0 as? ARPlaneAnchor }.forEach {
            planeManager.removePlane(for: $0)
        }
    }
    
    // MARK: - Game Flow Control
    
    // '새 게임 준비' 액션을 처리하는 함수
    func setupNewGame(with players: [PlayerModel]) {
        gameFlow.setupNewGame(with: players)
    }
    
    // 새 말 놓을 때
    func showDestinationsForNewPiece() {
        gameFlow.showDestinationsForNewPiece()
    }
    
    // 윷 결과 업데이트 후 -> 움직일 말 선택
    func yutThrowCompleted(with result: YutResult) {
        gameFlow.yutThrowCompleted(with: result)
    }
    
    func endTurn() {
        gameFlow.endTurn()
    }
    
    // MARK: - MPC 협업 기능
    
    // Host가 말판을 배치할 때 호출
    func placeBoardForCollaboration(at position: SIMD3<Float>) {
        guard collab.isHost else { return }
        let anchor = ARAnchor(name: "YutBoardAnchor", transform: matrix_identity_float4x4)
        arView?.session.add(anchor: anchor)
        print("🎯 Host: 말판 배치 완료 - Guest들과 공유 중...")
    }
    
    // 게임 상태를 다른 피어들과 동기화
    func syncGameState() {
        guard let arState = self.arState else { return }
        
        let gameState = GameStateData(
            currentPlayer: arState.gameManager.currentPlayer.name,
            gamePhase: arState.gamePhase,
            yutResult: arState.gameManager.yutResult
        )
        collab.sendGameState(gameState)
    }
    
    // MARK: - Piece Movement Logic
    
    /// 1. GestureHandler로부터 최초 이동 요청을 받습니다.
    func processMoveRequest(pieces: [PieceModel], to destination: String) {
        gameFlow.processMoveRequest(pieces: pieces, to: destination)
    }
    
    /// 2. 사용자가 '업기'/'따로가기'를 선택하면 호출됩니다.
    func resolveMove(carry: Bool) {
        gameFlow.resolveMove(carry: carry)
    }
    
    /// 3. 모든 정보가 확정된 후, 실제 말 이동 및 게임 상태 변경을 실행하는 함수
    private func executeMove(pieces: [PieceModel], to destination: String, didCarry: Bool) {
        guard let arState = self.arState,
              let pieceManager = self.pieceManager,
              let representativePiece = pieces.first else { return }
        
        var finalResult: GameResult?

        // --- 논리적 처리 ---
        // 업은 말들을 순서대로 하나씩 이동시킵니다.
        for (index, piece) in pieces.enumerated() {
            // 첫 번째 말만 잡기/업기 여부를 결정하고, 나머지는 무조건 업습니다(따라갑니다).
            let isFirstPiece = (index == 0)
            let result = arState.gameManager.applyMoveResult(
                piece: piece,
                to: destination,
                userChooseToCarry: isFirstPiece ? didCarry : true // 두 번째 말부터는 무조건 업기
            )
            if isFirstPiece {
                finalResult = result // 첫 번째 말의 결과만 최종 결과로 사용합니다.
            }
        }

        guard let finalResult = finalResult else { return }

        // --- 시각적 처리 ---
        // a. 잡은 말이 있다면, 잡힌 말들을 판에서 치웁니다.
        if finalResult.didCapture {
            print("💥 잡힌 말들 처리 시작: \(finalResult.capturedPieces.map { $0.id.uuidString })")
            pieceManager.resetPieces(finalResult.capturedPieces)
        }
        
        // b. 모든 말을 이동시킵니다.
        for piece in pieces {
            if piece.entity.parent == nil { // 판 밖에 있던 새 말인 경우
                pieceManager.placePieceOnBoard(piece: piece, on: destination)
            } else { // 이미 판 위에 있던 말인 경우
                pieceManager.movePiece(piece: piece.entity, to: destination)
            }
        }
        
        // c. 이동 후, 해당 타일의 모든 말을 시각적으로 재배치합니다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pieceManager.arrangePiecesOnTile(destination, didCarry: finalResult.didCarry)
        }
        
        // --- 후처리 ---
        pieceManager.clearAllHighlights()
        arState.selectedPieces = nil
        arState.availableDestinations = []
        arState.pendingMove = nil
        
        // 턴 관리
        if finalResult.didCapture {
            print("👍 상대 말을 잡았습니다! 한 번 더 던지세요.")
            arState.gamePhase = .readyToThrow
        } else {
            endTurn()
        }
    }
    
}

// 게임 상태 데이터 구조
struct GameStateData: Codable {
    let currentPlayer: String
    let gamePhaseString: String
    let yutResultInt: Int?
    
    init(currentPlayer: String, gamePhase: GamePhase, yutResult: YutResult?) {
        self.currentPlayer = currentPlayer
        self.gamePhaseString = String(describing: gamePhase)
        self.yutResultInt = yutResult?.rawValue
    }
}
