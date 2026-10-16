<script>
  import { onMount } from 'svelte'
  import AppIcon from './lib/AppIcon.svelte'
  import InstallButton from './lib/InstallButton.svelte'
  import VersionSelect from './lib/VersionSelect.svelte'
  import { when, dateTime, versionText } from './lib/format.js'

  const channels = [
    { id: 'debug', title: 'Debug' },
    { id: 'release', title: 'Release' },
  ]

  let data = $state(null)
  let error = $state(null)
  /** app.key → id de la build elegida en el desplegable (por defecto, la última). */
  let chosen = $state({})
  let route = $state(parseHash())

  /** "#/debug" → lista; "#/release/app/ios%3Acom.x" → ficha de esa app. */
  function parseHash() {
    const [, channel, view, key] = location.hash.split('/')
    return {
      channel: channels.some((c) => c.id === channel) ? channel : 'debug',
      app: view === 'app' && key ? decodeURIComponent(key) : null,
    }
  }

  function go(channel, app = null) {
    location.hash = app ? `/${channel}/app/${encodeURIComponent(app)}` : `/${channel}`
  }

  async function refresh() {
    try {
      const response = await fetch('/api/apps', { cache: 'no-store' })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      data = await response.json()
      error = null
    } catch (e) {
      error = 'No se pudo cargar la lista de builds.'
    }
  }

  onMount(() => {
    refresh()
    const onHash = () => {
      route = parseHash()
      window.scrollTo(0, 0)
    }
    const onVisible = () => document.visibilityState === 'visible' && refresh()
    addEventListener('hashchange', onHash)
    document.addEventListener('visibilitychange', onVisible)
    // Una build nueva aparece sola mientras la página está abierta.
    const timer = setInterval(() => document.visibilityState === 'visible' && refresh(), 15_000)
    return () => {
      removeEventListener('hashchange', onHash)
      document.removeEventListener('visibilitychange', onVisible)
      clearInterval(timer)
    }
  })

  const apps = $derived(data?.channels?.[route.channel] ?? [])
  const detail = $derived(route.app ? apps.find((a) => a.key === route.app) : null)

  function selectedBuild(app) {
    return app.builds.find((b) => b.id === chosen[app.key]) ?? app.builds[0]
  }

  function countOf(channel) {
    return data?.channels?.[channel]?.length ?? 0
  }

  const platformTitle = (p) => (p === 'ios' ? 'iOS' : 'Android')
  const channelTitle = (c) => channels.find((x) => x.id === c)?.title ?? c
</script>

{#if route.app}
  <!-- Ficha de una app, como la de TestFlight. -->
  <nav class="navbar">
    <a href="#/{route.channel}" class="back">
      <svg width="12" height="20" viewBox="0 0 12 20" aria-hidden="true">
        <path d="M10 2 2 10l8 8" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
      Apps
    </a>
  </nav>

  {#if detail}
    {@const build = selectedBuild(detail)}
    <header class="hero">
      <AppIcon name={detail.name} platform={detail.platform} src={build.icon} size={108} />
      <div class="hero-text">
        <h1>{detail.name}</h1>
        <p>{platformTitle(detail.platform)} · {channelTitle(route.channel)}</p>
        <InstallButton {build} prominent onInstalled={refresh} />
      </div>
    </header>

    <h2 class="section-title">Versión</h2>
    <div class="group">
      <div class="row picker">
        <span>Build a instalar</span>
        <VersionSelect builds={detail.builds} bind:selected={chosen[detail.key]} />
      </div>
    </div>
    <p class="footnote">
      {#if detail.platform === 'ios' && route.channel === 'debug'}
        Se instala en los iPhone registrados con el Modo Desarrollador activado. Si ya tienes la app,
        se reemplaza y conservas sus datos.
      {:else if detail.platform === 'ios'}
        Las builds Release se descargan como .ipa para subirlas con Transporter.
      {:else}
        Android instala la APK directamente; los AAB se descargan para subirlos a Google Play.
      {/if}
    </p>

    <h2 class="section-title">Información</h2>
    <dl class="group">
      <div class="row"><dt>Versión</dt><dd>{build.version}</dd></div>
      <div class="row"><dt>Build</dt><dd>{build.build}</dd></div>
      <div class="row"><dt>Publicada</dt><dd>{dateTime(build.createdAt)}</dd></div>
      <div class="row"><dt>Tamaño</dt><dd>{build.size}</dd></div>
      <div class="row"><dt>Archivo</dt><dd>{build.file}</dd></div>
      <div class="row"><dt>Identificador</dt><dd class="mono">{detail.bundleId}</dd></div>
    </dl>

    <h2 class="section-title">
      {detail.builds.length === 1 ? 'Build' : `Todas las builds (${detail.builds.length})`}
    </h2>
    <ul class="group">
      {#each detail.builds as item, i (item.id)}
        <li class="row build" class:current={item.id === build.id}>
          <button class="build-text" onclick={() => (chosen[detail.key] = item.id)}>
            <strong>Versión {versionText(item)}{#if i === 0}<span class="tag">Última</span>{/if}</strong>
            <small>{when(item.createdAt)} · {item.size}</small>
          </button>
          <InstallButton build={item} onInstalled={refresh} />
        </li>
      {/each}
    </ul>
  {:else if data}
    <p class="empty">Esta app ya no tiene builds en {channelTitle(route.channel)}.</p>
  {/if}
{:else}
  <!-- Lista de apps. -->
  <header class="large-title">
    <h1>BuildCloud</h1>
    {#if data?.certificate}<a href="/certificado" class="nav-link">Certificado</a>{/if}
  </header>

  <div class="segmented" role="tablist">
    {#each channels as channel}
      <button
        role="tab"
        aria-selected={route.channel === channel.id}
        class:active={route.channel === channel.id}
        onclick={() => go(channel.id)}
      >
        {channel.title}
        {#if data}<span class="count">{countOf(channel.id)}</span>{/if}
      </button>
    {/each}
  </div>

  {#if data?.secureBase}
    <p class="notice">
      Estás en la versión sin cifrar. Para instalar en iPhone, instala una vez el
      <a href="/certificado">certificado de BuildCloud</a> y abre
      <a href="{data.secureBase}/">{data.secureBase}</a>.
    </p>
  {/if}

  {#if error}
    <p class="notice error">{error} <button class="link" onclick={refresh}>Reintentar</button></p>
  {/if}

  {#if data}
    {#if apps.length === 0}
      <div class="empty">
        <p>Sin builds todavía</p>
        <small>Compila con <code>buildcloud build &lt;proyecto&gt; {route.channel}</code></small>
      </div>
    {:else}
      <h2 class="section-title">Apps</h2>
      <ul class="group apps">
        {#each apps as app (app.key)}
          {@const build = selectedBuild(app)}
          <li class="row app">
            <a class="app-link" href="#/{route.channel}/app/{encodeURIComponent(app.key)}" aria-label="Ver {app.name}">
              <AppIcon name={app.name} platform={app.platform} src={build.icon} />
            </a>
            <div class="app-text">
              <a href="#/{route.channel}/app/{encodeURIComponent(app.key)}" class="app-name">{app.name}</a>
              <VersionSelect builds={app.builds} bind:selected={chosen[app.key]} compact />
              <small>{platformTitle(app.platform)} · {when(build.createdAt)}</small>
            </div>
            <InstallButton {build} onInstalled={refresh} />
          </li>
        {/each}
      </ul>
    {/if}
  {:else if !error}
    <div class="loading" aria-label="Cargando"></div>
  {/if}
{/if}

<style>
  h1, h2, p { margin: 0; }

  /* --- Cabeceras --- */
  .large-title {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    padding: 52px 4px 10px;
  }
  .large-title h1 { font-size: 34px; font-weight: 700; letter-spacing: 0.01em; }
  .nav-link { font-size: 17px; padding-bottom: 6px; }

  .navbar {
    position: sticky;
    top: 0;
    z-index: 1;
    display: flex;
    align-items: center;
    height: 44px;
    margin: 0 -16px;
    padding: 0 8px;
    background: var(--bg);
  }
  .back { display: inline-flex; align-items: center; gap: 6px; font-size: 17px; padding: 8px; }

  .hero { display: flex; gap: 16px; align-items: flex-start; padding: 12px 4px 8px; }
  .hero-text { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .hero-text h1 { font-size: 24px; font-weight: 700; line-height: 1.15; overflow-wrap: anywhere; }
  .hero-text p { color: var(--secondary); font-size: 15px; margin-bottom: 10px; }

  /* --- Control segmentado --- */
  .segmented {
    display: flex;
    padding: 2px;
    margin: 6px 0 4px;
    border-radius: 9px;
    background: var(--fill);
  }
  .segmented button {
    flex: 1;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    height: 30px;
    border: 0;
    border-radius: 7px;
    background: transparent;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
  }
  .segmented button.active {
    background: var(--segment);
    font-weight: 600;
    box-shadow: 0 3px 8px rgba(0, 0, 0, 0.12), 0 3px 1px rgba(0, 0, 0, 0.04);
  }
  .count { color: var(--secondary); font-variant-numeric: tabular-nums; }

  /* --- Grupos insertados --- */
  .section-title {
    margin: 26px 16px 7px;
    color: var(--secondary);
    font-size: 13px;
    font-weight: 400;
    text-transform: uppercase;
    letter-spacing: 0.01em;
  }
  .group {
    margin: 0;
    padding: 0;
    list-style: none;
    border-radius: 10px;
    background: var(--card);
    overflow: hidden;
  }
  .row {
    position: relative;
    display: flex;
    align-items: center;
    gap: 12px;
    min-height: 44px;
    padding: 11px 16px;
    font-size: 17px;
  }
  .row + .row::before {
    content: '';
    position: absolute;
    top: 0;
    left: 16px;
    right: 0;
    border-top: 0.5px solid var(--separator);
  }
  .apps .row + .row::before { left: 88px; }
  .footnote { margin: 7px 16px 0; color: var(--secondary); font-size: 13px; line-height: 1.35; }

  dl.group .row { justify-content: space-between; }
  dt { flex: none; }
  dd { margin: 0; color: var(--secondary); text-align: right; overflow-wrap: anywhere; }
  .mono { font-family: ui-monospace, 'SF Mono', monospace; font-size: 14px; }

  .picker { justify-content: space-between; }

  /* --- Fila de app --- */
  .app { padding: 12px 16px; }
  .app-link { flex: none; display: flex; }
  .app-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .app-name {
    color: var(--label);
    font-size: 17px;
    font-weight: 600;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .app-text small { color: var(--secondary); font-size: 13px; }

  /* --- Fila de build en la ficha --- */
  .build-text {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 2px;
    padding: 0;
    border: 0;
    background: none;
    text-align: left;
    cursor: pointer;
  }
  .build-text strong { font-size: 17px; font-weight: 400; display: inline-flex; align-items: center; gap: 8px; }
  .build.current .build-text strong { font-weight: 600; }
  .build-text small { color: var(--secondary); font-size: 13px; }
  .tag {
    padding: 1px 7px;
    border-radius: 999px;
    background: var(--blue);
    color: white;
    font-size: 11px;
    font-weight: 600;
  }

  /* --- Avisos y estados vacíos --- */
  .notice {
    margin-top: 14px;
    padding: 12px 14px;
    border-radius: 10px;
    background: color-mix(in srgb, var(--orange) 16%, var(--card));
    font-size: 14px;
    line-height: 1.4;
  }
  .notice.error { background: color-mix(in srgb, var(--red) 14%, var(--card)); }
  .link { border: 0; background: none; color: var(--blue); padding: 0; cursor: pointer; }
  .empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    padding: 80px 16px;
    color: var(--secondary);
    text-align: center;
  }
  .empty p { font-size: 20px; font-weight: 600; color: var(--label); }
  .loading {
    width: 28px;
    height: 28px;
    margin: 80px auto;
    border-radius: 50%;
    border: 3px solid var(--fill-strong);
    border-top-color: var(--secondary);
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
