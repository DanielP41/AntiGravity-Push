# AntiGravity-Push
<img width="1309" height="378" alt="Screenshot 2026-01-11 024617" src="https://github.com/user-attachments/assets/0c9ca70c-a523-4f31-800a-945be9fee319" />

Recibe notificaciones push en tu teléfono cuando Antigravity necesite tu intervención. Responde con botones directamente desde la notificación.

## Inicio Rápido

### 1. Instala la app ntfy en tu teléfono

- **iOS:** [App Store](https://apps.apple.com/app/ntfy/id1625396347)
- **Android:** [Play Store](https://play.google.com/store/apps/details?id=io.heckel.ntfy)

### 2. Ejecuta Antigravity Push

```powershell
.\AntigravityPush.ps1
```

En la primera ejecución, se te pedirá que crees un nombre de tema (topic) único. Suscríbete a este tema en la aplicación ntfy.

### 3. Envía una notificación de prueba

Selecciona la opción **[2] Send test notification** en el menú del script.

## Uso desde Línea de Comandos (CLI)

Puedes usar Antigravity Push desde otros scripts o terminales sin entrar al menú interactivo:

```powershell
# Enviar notificación simple
.\AntigravityPush.ps1 -Message "Tarea terminada exitosamente"

# Enviar notificación con botones y esperar respuesta
.\AntigravityPush.ps1 -Message "Build listo. ¿Desplegar?" -Keys "Sí [y],No [n]" -Listen
```

- `-Message`: El mensaje de la notificación.
- `-Title`: (Opcional) Título personalizado.
- `-Keys`: Lista de botones (formato: `Texto [tecla]`). Si no pones `[tecla]`, usará la primera letra.
- `-Listen`: Si se incluye, el script se queda esperando una respuesta del móvil y luego se cierra.
- `-Priority`: Prioridad de la notificación (1 a 5).

## Historial de Notificaciones

El script guarda automáticamente las últimas **15 notificaciones** en un archivo `history.json`. Este historial se muestra en el menú principal y se actualiza en tiempo real cuando recibes una respuesta desde tu teléfono.

Puedes consultar el historial para verificar qué acciones autorizaste anteriormente.

## Input de Texto Remoto

Necesitas escribir un comando largo, un nombre de archivo o cualquier texto libre?

1. Envía una notificación incluyendo un botón con la etiqueta `[input]`.
   Ejemplo: `.\AntigravityPush.ps1 -Message "Nombre del commit?" -Keys "Texto [input]"`
2. En tu celular, presiona el botón **Texto**.
3. Recibirás una notificación confirmando: *"Esperando Texto"*.
4. Abre la app ntfy, entra al tema y **escribe tu respuesta** como un mensaje normal.
5. El texto se escribirá automáticamente en tu terminal.

## Cómo funciona

```
Antigravity solicita permiso / notificación personalizada
        ↓
Notificación push al teléfono
        ↓
Presionas "Allow" o "Deny" (o cualquier tecla configurada)
        ↓
Pulsación de tecla enviada a la terminal activa
```

