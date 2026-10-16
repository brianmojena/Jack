import CoreGraphics
import Foundation

// Datos de la oficina 2D. Solo los consume la interfaz del modo Normal.

/// Estado visual de un agente en la oficina.
public enum Office2DAgentState: String, Equatable, CaseIterable {
    case working    // ejecutando herramienta o escribiendo
    case thinking   // razonando
    case waiting    // espera respuesta o aprobación del usuario
    case blocked    // bloqueado
    case idle       // sin tarea / terminado
    case failed     // error
}

/// Agente tal y como lo dibuja la oficina.
public struct Office2DAgent: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// «claude», «codex», «opencode» u otro.
    public let kind: String
    public let state: Office2DAgentState
    /// Actividad real, p. ej. «Editando main.swift». nil si no hay.
    public let activity: String?
    /// Semilla estable para color y rasgos (hash del id).
    public let seed: UInt64

    public init(id: String, name: String, kind: String, state: Office2DAgentState, activity: String?, seed: UInt64) {
        self.id = id; self.name = name; self.kind = kind; self.state = state; self.activity = activity; self.seed = seed
    }
}

/// Puesto de trabajo calculado por el layout, en coordenadas de la escena.
public struct Office2DDeskSlot: Equatable {
    public let index: Int
    /// Rectángulo del escritorio (incluye monitor).
    public let deskFrame: CGRect
    /// Punto donde se sienta el personaje (pies).
    public let seat: CGPoint
    /// Escala de dibujo para escritorio y personaje (1 = tamaño base).
    public let scale: CGFloat

    public init(index: Int, deskFrame: CGRect, seat: CGPoint, scale: CGFloat) {
        self.index = index; self.deskFrame = deskFrame; self.seat = seat; self.scale = scale
    }
}

/// Distribución completa de la escena para un tamaño dado.
public struct Office2DLayout: Equatable {
    public let size: CGSize
    public let desks: [Office2DDeskSlot]
    /// Zona de descanso (sofá, café) a la derecha.
    public let loungeFrame: CGRect
    /// Puntos donde pueden quedarse los agentes inactivos.
    public let loungeSpots: [CGPoint]
    /// Altura de la línea del suelo (todo lo que está por encima es pared).
    public let floorY: CGFloat

    public init(size: CGSize, desks: [Office2DDeskSlot], loungeFrame: CGRect, loungeSpots: [CGPoint], floorY: CGFloat) {
        self.size = size; self.desks = desks; self.loungeFrame = loungeFrame; self.loungeSpots = loungeSpots; self.floorY = floorY
    }
}

/// Pose del personaje.
public enum Office2DPose: Equatable {
    case seatedTyping
    case seatedThinking
    case raisedHand
    case walking
    case standingCoffee
    case sittingSofa
    case celebrating
    case slumped        // fallo
}

/// Colocación de un personaje en un instante.
public struct Office2DPlacement: Equatable {
    public let position: CGPoint   // pies, coordenadas de la escena
    public let pose: Office2DPose
    public let facingLeft: Bool
    public let scale: CGFloat

    public init(position: CGPoint, pose: Office2DPose, facingLeft: Bool, scale: CGFloat) {
        self.position = position; self.pose = pose; self.facingLeft = facingLeft; self.scale = scale
    }
}
