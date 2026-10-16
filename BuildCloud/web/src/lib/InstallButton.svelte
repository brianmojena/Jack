<script>
  import { installs, follow } from './installs.svelte.js'

  /**
   * Botón de TestFlight: cápsula gris con texto azul en las listas, azul relleno en la ficha.
   * En builds de iOS Debug se convierte en un anillo de progreso mientras el iPhone descarga.
   */
  let { build, prominent = false, onInstalled } = $props()

  const state = $derived(installs[build.id])
  const busy = $derived(state?.active)
  const label = $derived.by(() => {
    if (!state) return build.label
    switch (state.phase) {
      case 'waiting': return 'Esperando…'
      case 'downloading': return `${Math.round(state.fraction * 100)} %`
      case 'installing': return 'Instalando…'
      case 'done': return '✓ Lista'
      case 'failed': return 'Falló, reintenta'
    }
    return build.label
  })

  const radius = 8
  const circumference = 2 * Math.PI * radius

  function click() {
    follow(build, onInstalled)
  }
</script>

<a
  class="button"
  class:prominent
  class:busy
  class:done={state?.phase === 'done'}
  class:failed={state?.phase === 'failed'}
  class:secondary={!build.installable}
  href={build.link}
  onclick={click}
  aria-live="polite"
>
  {#if busy}
    <svg width="18" height="18" viewBox="0 0 20 20" aria-hidden="true">
      <circle cx="10" cy="10" r={radius} fill="none" class="track" stroke-width="3" />
      <circle
        cx="10" cy="10" r={radius} fill="none" class="value" stroke-width="3" stroke-linecap="round"
        transform="rotate(-90 10 10)"
        stroke-dasharray={circumference}
        stroke-dashoffset={circumference * (1 - (state?.fraction ?? 0))}
      />
    </svg>
  {/if}
  <span>{label}</span>
</a>

<style>
  .button {
    flex: none;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    min-width: 92px;
    height: 30px;
    padding: 0 16px;
    border-radius: 999px;
    background: var(--fill);
    color: var(--blue);
    font-size: 15px;
    font-weight: 700;
    letter-spacing: -0.01em;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    transition: background 0.2s, color 0.2s, transform 0.1s;
  }
  .button:active { transform: scale(0.96); opacity: 0.7; }
  .button.prominent {
    height: 34px;
    min-width: 120px;
    background: var(--blue);
    color: white;
    font-size: 16px;
  }
  .button.busy { pointer-events: none; padding-left: 10px; }
  .button.done { background: var(--green); color: white; }
  .button.failed { background: var(--red); color: white; }
  .track { stroke: currentColor; opacity: 0.25; }
  .value { stroke: currentColor; transition: stroke-dashoffset 0.4s ease; }
</style>
