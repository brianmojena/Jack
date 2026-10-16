<script>
  /**
   * Icono de la app: el real de la build ([src]) o, si no trae o no carga, un squircle con la
   * inicial (azul en iOS, verde en Android).
   */
  let { name, platform, src = null, size = 60 } = $props()
  const letter = $derived((name ?? '?').trim().charAt(0).toUpperCase() || '?')
  let failed = $state(false)
  $effect(() => {
    src
    failed = false
  })
</script>

{#if src && !failed}
  <img
    class="icon"
    {src}
    alt=""
    width={size}
    height={size}
    style:border-radius="{size * 0.225}px"
    onerror={() => (failed = true)}
  />
{:else}
  <div
    class="icon letter {platform}"
    style:width="{size}px"
    style:height="{size}px"
    style:border-radius="{size * 0.225}px"
    style:font-size="{size * 0.44}px"
    aria-hidden="true"
  >
    {letter}
  </div>
{/if}

<style>
  .icon {
    flex: none;
    display: block;
    object-fit: cover;
    box-shadow: inset 0 0 0 0.5px rgba(0, 0, 0, 0.12), 0 0 0 0.5px var(--separator);
  }
  .letter {
    display: grid;
    place-items: center;
    color: white;
    font-weight: 600;
    letter-spacing: -0.02em;
  }
  .ios { background: linear-gradient(160deg, #5ac8fa, #007aff 55%, #0055d4); }
  .android { background: linear-gradient(160deg, #6ee089, #34c759 55%, #1f9e43); }
</style>
