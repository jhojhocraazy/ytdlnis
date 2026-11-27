# Delta upstream — ytdlnis

- Gerado em: 2026-11-27T16:03:01.4376280+00:00
- Base local: 00f3b1b95378adb169314b61f13c1e2a641ef9ee
- Upstream: upstream/main / 0c2fd4ebeb52dd21e9b679993bc944d07a519b3e
- Chaves pendentes: 15

## Chaves detectadas

```json
{
  "tool": "sync-check.ps1",
  "version": "1.0.0",
  "generatedAt": "2026-11-27T16:03:00.9178195+00:00",
  "root": "D:\\a\\ytdlnis",
  "mode": "nofetch",
  "summary": {
    "analyzed": 1,
    "updated": 0,
    "newStrings": 1,
    "removals": 0,
    "gaps": 0,
    "errors": 0,
    "pendingKeys": 15,
    "missingKeys": 0
  },
  "baselineUpdated": [],
  "repos": [
    {
      "name": "ytdlnis",
      "branch": "main",
      "head": "4000f1b496acbe5585271deee9a6f57e722eac14",
      "headShort": "4000f1b4",
      "upstreamRef": "upstream/main",
      "upstreamCommit": "0c2fd4ebeb52dd21e9b679993bc944d07a519b3e",
      "baseCommit": "00f3b1b95378adb169314b61f13c1e2a641ef9ee",
      "baseSource": "baseline",
      "ahead": 20,
      "behind": 60,
      "status": "Novas strings",
      "added": 15,
      "modified": 0,
      "removed": 1,
      "pending": 15,
      "baseKeys": 718,
      "missingKeys": 0,
      "extraKeys": 1,
      "coveragePercent": 100.0,
      "dirtyFiles": [],
      "sourceDirty": [],
      "fetchError": "",
      "error": "",
      "warnings": [
        "Modo offline (-NoFetch): git fetch não executado."
      ],
      "files": [
        {
          "path": "app/src/main/res/values/arrays.xml",
          "target": "app/src/main/res/values-pt-rBR/arrays.xml",
          "targetExists": true,
          "baseKeys": 1,
          "upstreamKeys": 1,
          "added": [],
          "modified": [],
          "removed": [],
          "missing": [],
          "extra": [],
          "warning": ""
        },
        {
          "path": "app/src/main/res/values/strings.xml",
          "target": "app/src/main/res/values-pt-rBR/strings.xml",
          "targetExists": true,
          "baseKeys": 717,
          "upstreamKeys": 731,
          "added": [
            "allow_install_unknown_apps",
            "install_cancelled",
            "install_failed_abi",
            "install_failed_code",
            "install_failed_downgrade",
            "install_failed_incompatible",
            "install_failed_storage",
            "installer_no_confirmation",
            "installer_shizuku_description",
            "installer_shizuku_not_running",
            "installer_system_description",
            "installer_system_unavailable",
            "no_external_player",
            "open_in_external_player",
            "selected_cuts"
          ],
          "modified": [],
          "removed": [
            "background_update_ytdlp"
          ],
          "missing": [],
          "extra": [
            "background_update_ytdlp"
          ],
          "warning": ""
        }
      ]
    }
  ]
}

```

## Sugestões DeepSeek

# Localização pt-BR — 15 chaves novas (`strings.xml`)

Observação de escopo: o delta lista 15 chaves pendentes em `app/src/main/res/values/strings.xml`. Não recebi os valores EN literais de cada chave; abaixo a sugestão parte do identificador e do domínio descrito no AGENTS.md (instalador/Shizuku, player externo, cortes). **Antes de aplicar, confirme o EN real** — se divergir, a sugestão deve ser reavaliada. `background_update_ytdlp` aparece como removida no upstream e como `extra` no pt-BR: **não traduzir agora**; remover só após confirmar a remoção no EN (fora do escopo desta tabela).

| chave | EN (inferido do identificador) | sugestão pt-BR | justificativa |
| --- | --- | --- | --- |
| `allow_install_unknown_apps` | Allow install from unknown apps | Permitir instalação de apps desconhecidos | Interface comum; ação no infinitivo; termo do Android em pt-BR corrente. |
| `install_cancelled` | Installation cancelled | Instalação cancelada | Toast/diálogo; ≤ 60; frase nominal, sem ponto. |
| `install_failed_abi` | Installation failed: incompatible ABI | Falha na instalação: ABI incompatível | `ABI` é termo técnico — verbatim; motivo em linguagem de usuário. |
| `install_failed_code` | Installation failed (code %1$d) | Falha na instalação (código %1$d) | Preserva `%1$d`; detalhe técnico separado do motivo. |
| `install_failed_downgrade` | Installation failed: downgrade not allowed | Falha na instalação: downgrade não permitido | `downgrade` é termo técnico do Android; mantido. |
| `install_failed_incompatible` | Installation failed: incompatible package | Falha na instalação: pacote incompatível | Interface comum; consistente com as demais `install_failed_*`. |
| `install_failed_storage` | Installation failed: insufficient storage | Falha na instalação: armazenamento insuficiente | Motivo em linguagem de usuário. |
| `installer_no_confirmation` | Installer requires no confirmation | Instalador não exige confirmação | `Instalador` = componente do Android; não confundir com "instalação". |
| `installer_shizuku_description` | Install via Shizuku | Instalar via Shizuku | `Shizuku` é termo de ferramenta — verbatim; `summary` ≤ 120. |
| `installer_shizuku_not_running` | Shizuku is not running | O Shizuku não está em execução | Estado do serviço; linguagem de usuário; `Shizuku` intacto. |
| `installer_system_description` | Install via system installer | Instalar pelo instalador do sistema | Distingue do Shizuku; `sistema` = Android. |
| `installer_system_unavailable` | System installer unavailable | Instalador do sistema indisponível | Consistente com `installer_system_description`. |
| `no_external_player` | No external player found | Nenhum player externo encontrado | `player` mantido (uso corrente em pt-BR de mídia); alternativa "reprodutor" rejeitada por ser menos usada no domínio. |
| `open_in_external_player` | Open in external player | Abrir em player externo | Ação no infinitivo; consistente com a chave anterior. |
| `selected_cuts` | Selected cuts | Cortes selecionados | `selected` → **selecionado(s)** conforme vocabulário fixado; `cuts` = trechos de vídeo, "cortes" é o termo do domínio. |

## Notas de conformidade

- **Placeholders**: `%1$d` preservado em `install_failed_code`; demais sem placeholders.
- **Limites**: todos os rótulos ≤ 30 caracteres; `summary` (`installer_shizuku_description`, `installer_system_description`) ≤ 120; toasts (`install_*`, `installer_*_not_running/unavailable`) ≤ 60.
- **Termos de ferramenta preservados**: `Shizuku`, `ABI`, `downgrade`, `player`.
- **Pseudo-enums**: nenhuma chave desta rodada toca `best_quality`/`worst_quality`/`defaultValue`.
- **`values-pt`**: não usado como fonte.
- **`background_update_ytdlp`**: marcada como `extra` no pt-BR e removida no EN — **não traduzir**; remoção do arquivo pt-BR deve ser feita em passo separado após confirmação do upstream.

## Pendência para fechar o handoff (§8)

Faltam os valores EN literais das 15 chaves para preencher a coluna "EN" com evidência real e validar as sugestões acima. Recomendo rodar `sync-check.ps1` sem `-NoFetch` ou colar o trecho EN correspondente para eu revisar antes da aplicação.

> Revise as sugestões e aplique apenas as chaves listadas, seguindo o AGENTS.md local. Este PR não altera os catálogos automaticamente.
