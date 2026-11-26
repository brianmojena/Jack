// TODO(port): SessionStore viene de SessionStore.swift. No es persistencia: es el cliente en vivo de la API del socket de herdr
// (instantánea de sesión, suscripciones y reconexión con retroceso). Depende de HerdrSnapshot, ConnectionState y AgentKind
// (Models.swift), de HerdrAPIClient y HerdrTransportError (UnixSocketTransport.swift, socket Unix) y de
// ExecutableResolver.defaultSocketPath (ExecutableResolver.swift). En Windows haría falta otro transporte (tubería con nombre)
// y conviene confirmar antes si herdr entra en el alcance del modo Normal.
