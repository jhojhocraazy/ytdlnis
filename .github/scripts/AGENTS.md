# AGENTS.md — Diretriz local de localização: ytdlnis

## 1. Domínio

Frontend Android para o yt-dlp: fila de downloads, padrões de nomenclatura de arquivo, observação de
fontes e playlists, recodificação, cookies, tokens de prova de origem e execução de JS. Também expõe
superfície de Intents (VIEW/SEND no manifesto) e integração com automação externa documentada nos
READMEs.

O usuário trata o app como ferramenta de linha de comando com interface gráfica: compara o rótulo do
app com a flag que viu na documentação do yt-dlp e desconfia quando os dois não batem.

## 2. Onde o texto vive (verificado no clone)

| Caminho | Papel |
| --- | --- |
| `app/src/main/res/values/strings.xml` | fonte EN |
| `app/src/main/res/values-pt-rBR/strings.xml` | pt-BR (já existe) |
| `app/src/main/res/values/arrays.xml` | fonte EN dos arrays |
| `app/src/main/res/values-pt-rBR/arrays.xml` | pt-BR: só nomes visíveis traduzidos |
| `fastlane/metadata/android/en-US/` | ficha da loja EN |
| `fastlane/metadata/android/pt-BR/` | ficha da loja pt-BR |
| `app/src/main/res/values-pt/strings.xml` | variante europeia — registro separado |
| `app/src/main/res/xml/` | telas de preferência; títulos vêm de `strings.xml` |
| `app/src/main/AndroidManifest.xml` | filtros `VIEW` e `SEND` |
| `docs/README-*.md` | integração com automação externa documentada (ex.: Tasker) |
| `app/src/main/java/...` | código; flags e argumentos do yt-dlp não se traduzem |

Fato estrutural: a automação externa aparece na **documentação** antes de aparecer em código. Antes de
prometer um comportamento, confirme o filtro de Intent e o extra realmente lidos.

## 3. Protocolo de inferência semântica

1. **Separar o que é flag do que é rótulo.** Se a string descreve um parâmetro do yt-dlp, o literal
   fica; só a explicação em volta é traduzida.
2. **Ler o consumidor.** É `summary` de preferência, `title` de tela, `Toast` ou diálogo? O limite e o
   tom mudam.
3. **Classificar em três faixas:**
   - *termo de ferramenta* — nome de biblioteca, token, runtime, automação; preservar;
   - *operação de download* — fila, lote, padrão de nomenclatura, recodificação; buscar o vocabulário usado
     pela comunidade brasileira do app e por gerenciadores de download;
   - *interface comum* — navegação e configurações; português corrente.
4. **Verificar promessa técnica.** Só descreva o que o yt-dlp e o app fazem de fato; se a UI sugere
   algo que depende de serviço externo, diga isso.
5. **Testar naturalidade** em tela de preferência, que é onde o texto se acumula.
6. **Registrar** decisão e evidência.

## 4. Invariantes técnicas

- Flags, argumentos, padrões de nome (`%(title)s`, `%(id)s`, `%(upload_date)s`), nomes de extractor e
  chaves de preferência ficam byte a byte.
- `%1$s`, `%1$d`, `%s`, `\'`, `&amp;` e tags `<b>`/`<i>` preservados.
- `values-pt` não é fonte para pt-BR.
- Ações de Intent (`ACTION_SEND`, `ACTION_VIEW`) e extras mantêm o identificador original.
- Exemplos de automação entram em bloco de código, sem tradução, com explicação ao lado.

## 5. Critérios de aceitação

- Rótulo de preferência ≤ 30 caracteres; `summary` ≤ 120; toast ≤ 60.
- Caixa de frase; ação no infinitivo; sem ponto final em rótulo.
- O nome do arquivo baixado é dado do usuário: não traduzir, não normalizar acento, não trocar `_` por espaço.
- Falha: motivo em linguagem de usuário e detalhe técnico separado.
- Consistência entre rótulo de tela e texto de ajuda.

## 6. Proibições

- Traduzir ou "corrigir" flag, padrão de nome ou nome de biblioteca.
- Prometer integração que só existe na documentação, sem checar o manifesto.
- Tratar `values-pt` como pt-BR.
- Criar string de UI em Kotlin.
- Misturar dois sinônimos para o mesmo conceito na mesma tela.

## 7. Verificação

```bash
pwsh -c "[xml](Get-Content -Raw 'app/src/main/res/values-pt-rBR/strings.xml') | Out-Null"
./gradlew :app:assembleDebug     # quando o SDK estiver disponível
```

Checklist: paridade de chaves, flags intactas, placeholders, limites de rótulo, `values-pt` intocado,
manifesto conferido antes de citar integração. Para arrays: 83 arrays espelhados, só `countries` e
`language_names` traduzidos, `countries_values`/`language_codes` byte a byte.

## 8. Handoff

| chave | EN | faixa (ferramenta / operação / interface) | pt-BR escolhido | evidência | alternativa rejeitada | motivo |
| --- | --- | --- | --- | --- | --- | --- |

Termo de ferramenta alterado exige justificativa explícita; por padrão, não se altera.

## 9. Estado verificado da localização pt-BR

Contagens conferidas por script sobre `values/` e `values-pt-rBR/` (2026-11-12):

| Recurso | EN | pt-BR |
| --- | --- | --- |
| `<string>` no arquivo | 704 | 704 |
| `<string>` traduzíveis | 701 | 701 |
| `<string>` `translatable="false"` | 3 | 3 (verbatim) |
| `<plurals>` | 9 | 9 |
| Formas de plural | `one`/`other` | `one`/`many`/`other` |
| Chaves traduzíveis (strings + plurais) | 710 | 710 |

- **Pseudo-enums intocáveis.** `best_quality` = `Melhor qualidade`, `worst_quality` = `Pior qualidade`
  e `defaultValue` = `Padrão` são gravadas em banco/preferências e comparadas em Kotlin
  (`UiUtil.kt`, `YTDLPUtil.kt`, `ProcessingSettingsModule.kt`, `DownloadViewModel.kt`). Retraduzi-las
  quebra registros antigos; mudança exige migração de dados.
- **Itens não traduzíveis.** `trendingPlaylist` (`ytdlnis-TRENDING`), `unfound_file` (`/404.404`) e
  `ytdlp` (`yt-dlp`) entram verbatim no arquivo pt-BR.
- **`arrays.xml`.** 83 arrays (58 `string-array` + 25 `array`). Só `countries` (237 países +
  `@string/defaultValue`) e `language_names` (107 idiomas + `@string/defaultValue`) têm nomes visíveis
  traduzidos, sempre na mesma ordem dos valores pareados. Ficam byte a byte: valores persistidos,
  códigos ISO (`countries_values`, `language_codes`, `subtitle_langs`), `filename_templates`, presets
  do FFmpeg e clientes do YouTube.
- **`fastlane/metadata/android/pt-BR/`.** `title.txt` (7), `short_description.txt` (51),
  `full_description.txt` (3060, 47 linhas, `<b>` balanceado) e `changelogs/109010100.txt` (7 linhas).

### Vocabulário fixado nesta rodada

| EN | pt-BR | Regra |
| --- | --- | --- |
| queue | **Fila** | nunca `Lista`; `Lista` é o layout `list` |
| embed | **Incorporar** | toda a tela de processamento |
| burn | **Incrustar** | não colide com `Incorporar` |
| selected | **selecionado(s)** | contadores `"$n ${...}"` |
| items / items_left | **item(ns)** / **item(ns) restante(s)** | idem, contador dinâmico |
| preferred_locale | **País preferido** | armazena código de país |
| (CLI/técnicos) | `--flat-playlist`, `-U`, `%(...)s`, `yt-dlp`, `FFmpeg`, `aria2c`, `SponsorBlock`, `PO Token`, `BgUtils`, `cookies`, `WebView`, `TYPE:audio`, `BACKGROUND:true` | verbatim |
