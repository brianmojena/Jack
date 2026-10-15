import CoreGraphics
import Foundation

// Contrato compartido de la vista «Oficina» (solo modo Normal).
// Los tipos y firmas públicas de este archivo son estables: las piezas de
// escena, personajes e integración dependen de ellos.

/// Estado visual de un agente en la oficina.
public enum OfficeAgentState: String, Equatable, CaseIterable {
    case working    // ejecutando herramienta o escribiendo
    case thinking   // razonando
    case waiting    // espera respuesta o aprobación del usuario
    case blocked    // bloqueado
    case idle       // sin tarea / terminado
    case failed     // error
}

/// Agente tal y como lo dibuja la oficina.
public struct OfficeAgent: Identifiable, Equatable {
    public let id: String
    public let name: String
    /// «claude», «codex», «opencode» u otro.
    public let kind: String
    public let state: OfficeAgentState
    /// Actividad real, p. ej. «Editando main.swift». nil si no hay.
    public let activity: String?
    /// Semilla estable para color y rasgos (hash del id).
    public let seed: UInt64

    public init(id: String, name: String, kind: String, state: OfficeAgentState, activity: String?, seed: UInt64) {
        self.id = id; self.name = name; self.kind = kind; self.state = state; self.activity = activity; self.seed = seed
    }
}

/// Puesto de trabajo calculado por el layout, en coordenadas de la escena.
public struct OfficeDeskSlot: Equatable {
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
public struct OfficeLayout: Equatable {
    public let size: CGSize
    public let desks: [OfficeDeskSlot]
    /// Zona de descanso (sofá, café) a la derecha.
    public let loungeFrame: CGRect
    /// Puntos donde pueden quedarse los agentes inactivos.
    public let loungeSpots: [CGPoint]
    /// Altura de la línea del suelo (todo lo que está por encima es pared).
    public let floorY: CGFloat

    public init(size: CGSize, desks: [OfficeDeskSlot], loungeFrame: CGRect, loungeSpots: [CGPoint], floorY: CGFloat) {
        self.size = size; self.desks = desks; self.loungeFrame = loungeFrame; self.loungeSpots = loungeSpots; self.floorY = floorY
    }
}

/// Pose del personaje.
public enum OfficePose: Equatable {
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
public struct OfficePlacement: Equatable {
    public let position: CGPoint   // pies, coordenadas de la escena
    public let pose: OfficePose
    public let facingLeft: Bool
    public let scale: CGFloat

    public init(position: CGPoint, pose: OfficePose, facingLeft: Bool, scale: CGFloat) {
        self.position = position; self.pose = pose; self.facingLeft = facingLeft; self.scale = scale
    }
}
