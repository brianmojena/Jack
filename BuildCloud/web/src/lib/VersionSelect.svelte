<script>
  import { versionText, when } from './format.js'

  /** Desplegable con todas las builds de una app; `selected` es el id de la build elegida. */
  let { builds, selected = $bindable(), compact = false } = $props()
</script>

<label class="select" class:compact>
  <select bind:value={selected} aria-label="Versión">
    {#each builds as build, i (build.id)}
      <option value={build.id}>
        {versionText(build)} · {when(build.createdAt)}{i === 0 ? ' · Última' : ''}
      </option>
    {/each}
  </select>
  <span class="shown">
    Versión {versionText(builds.find((b) => b.id === selected) ?? builds[0])}
    {#if builds.length > 1}<small>{builds.length}</small>{/if}
  </span>
  <svg width="10" height="14" viewBox="0 0 10 14" aria-hidden="true">
    <path d="M1.5 5 5 1.5 8.5 5M1.5 9 5 12.5 8.5 9" fill="none" stroke="currentColor" stroke-width="1.6"
          stroke-linecap="round" stroke-linejoin="round" />
  </svg>
</label>

<style>
  /* El <select> nativo va encima, invisible: en el iPhone abre la rueda del sistema. */
  .select {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    max-width: 100%;
    color: var(--secondary);
    font-size: 15px;
  }
  .select.compact { font-size: 13px; }
  select {
    position: absolute;
    inset: 0;
    width: 100%;
    opacity: 0;
    cursor: pointer;
    appearance: none;
  }
  .shown {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  small {
    padding: 0 6px;
    border-radius: 999px;
    background: var(--fill);
    font-size: 11px;
    font-weight: 600;
    line-height: 16px;
  }
  svg { flex: none; }
</style>
