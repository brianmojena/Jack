import SwiftUI

/// Jack en el iPhone: la misma oficina 3D que en la Mac (el motor de `Sources/Jack/Office/Engine` se compila en las dos apps),
/// manejada con los dedos. El iPhone no lanza agentes ni modelos: se los pide a la Mac de la red local, que los ejecuta y le
/// cuenta qué hace cada uno. Hasta que esa conexión exista, la oficina funciona sola (modo demostración).
@main
struct JackMobileApp: App {
    var body: some Scene {
        WindowGroup {
            MobileOfficeView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
