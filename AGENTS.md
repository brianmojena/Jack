# Instrucciones para todos los agentes

Estas instrucciones se aplican a todo el repositorio y a cualquier agente que trabaje en él.

## Nuevas funcionalidades y modo Light

- Ninguna nueva funcionalidad (`feat`) ni ampliación de una funcionalidad existente debe implementarse en el modo Light, salvo que el prompt del usuario lo solicite explícitamente para Light.
- Por defecto, las peticiones de nuevas funcionalidades se aplican únicamente al modo Normal. Una petición general para «Jack», «la app», «todos los modos» o para mantener paridad entre modos no autoriza incorporar esa funcionalidad a Light sin mencionar Light explícitamente.
- Esta regla también cubre cambios en el núcleo, drivers, servicios y componentes compartidos: evita que una nueva funcionalidad llegue indirectamente a Light. Si hace falta, limita el comportamiento nuevo al modo Normal y conserva el comportamiento existente de Light.
- No añadas a Light nuevos controles, paneles, comandos, integraciones, consultas automáticas ni tareas de fondo como parte de una `feat` no solicitada explícitamente para Light.
- Las correcciones de fallos y el mantenimiento de funcionalidades ya existentes en Light no autorizan añadir funcionalidades nuevas.
- Al revisar una `feat`, comprueba que Light mantiene su comportamiento anterior, salvo los cambios que el prompt haya pedido explícitamente para ese modo.

El objetivo es preservar el alcance reducido y el ahorro de batería del modo Light. No interpretes la conveniencia técnica, la reutilización de código ni una petición anterior como autorización para extender a Light una nueva `feat` del prompt actual.
