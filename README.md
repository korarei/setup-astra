# setup-astra

[Astra](https://github.com/korarei/AviUtl2_Astra) (`korarei/AviUtl2_Astra`) を GitHub Actions ランナー上にセットアップするアクション．

## 対応プラットフォーム

[korarei/AviUtl2_Astra](https://github.com/korarei/AviUtl2_Astra) のリリースバイナリ提供対象に準拠し，以下のランナー環境に対応している．

| OS | アーキテクチャ | 対象アセット |
|---|---|---|
| Windows | x64 | `astra-<tag>-windows-x64.zip` |
| Windows | ARM64 | `astra-<tag>-windows-arm64.zip` |
| Linux | x64 | `astra-<tag>-linux-x64.tar.gz` |

> [!IMPORTANT]
> 実行には `pwsh` (PowerShell 7.6 以上) が必要となる．GitHub ホストランナー (`windows-latest`，`windows-11-arm`，`ubuntu-latest` 等) ではランナーに含まれる `pwsh` を使用する．セルフホストランナーでは事前に PowerShell 7.6 以上をインストールする．
>
> 対象となる Astra のバージョンは `v0.7.0` 以降である．`v0.7.0` 未満のバージョンはサポートしない．

## 使い方

### 基本的な使い方

最新版の Astra をセットアップする．

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: korarei/setup-astra@v1

  - run: astra --version
```

### バージョンを指定する

`version` 入力でインストールするバージョンや SemVer 範囲を指定できる．

```yaml
steps:
  - uses: korarei/setup-astra@v1
    with:
      version: '0.10'
```

### ビルド・リリースを行う例

`astra.toml` を含むリポジトリで，ビルドや配布パッケージの作成を行う例である．

```yaml
name: Build

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - uses: korarei/setup-astra@v1
        with:
          version: '^0.10.0'

      - run: astra release
```

### 出力を利用する

```yaml
steps:
  - id: astra
    uses: korarei/setup-astra@v1
    with:
      version: '0.10.0'

  - run: |
      echo "Version: ${{ steps.astra.outputs.version }}"
      echo "Tag: ${{ steps.astra.outputs.tag }}"
      echo "Path: ${{ steps.astra.outputs.path }}"
```

## 入力

| 名前 | 必須 | 既定値 | 説明 |
|---|---|---|---|
| `version` | いいえ | `latest` | インストールする Astra のバージョン，または SemVer 範囲 |
| `token` | いいえ | `${{ github.token }}` | GitHub Releases API の呼び出しに使用するトークン |

## 出力

| 名前 | 説明 |
|---|---|
| `version` | インストールされた Astra のバージョン (先頭の `v` を除いた値，例: `0.10.0`) |
| `tag` | インストールされた GitHub Release のタグ名 (例: `v0.10.0`) |
| `path` | `astra` 実行ファイルが配置されたディレクトリパス |

## バージョン指定

`version` には以下の形式を指定できる．

| 形式 | 指定例 | 説明 |
|---|---|---|
| 最新版 | `latest` | 最新の安定版リリースを取得 |
| 厳密指定 | `0.10.0`，`v0.10.0`，`=0.10.0` | 指定したバージョンのみを取得 |
| 部分指定・ワイルドカード | `0.10`，`0.10.*`，`0.10.x`，`0` | 条件を満たす最新の安定版リリースを取得 |
| キャレット・チルダ範囲 | `^0.10.0`，`~0.10.0` | SemVer のキャレット／チルダ規則に基づく範囲指定 |
| 比較演算子・複合範囲 | `>=0.8.0 <0.11.0`，`>=0.8.0, <0.11.0`，`0.9 \|\| 0.10`，`0.8.0 - 0.10.0` | AND / OR / ハイフン範囲による条件指定 |

> [!NOTE]
> プレリリース版は `latest` や通常の範囲指定では選択されず，厳密指定した場合のみ対象となる．また，`v0.7.0` 以降かつ実行環境向けのバイナリアセットを含む最新バージョンが選ばれる (`v0.7.0` 未満を指定した場合はエラーとなる)．

## 動作仕様

- ダウンロードしたバイナリは `RUNNER_TOOL_CACHE` (`astra/<version>/<arch>/`) に配置される．同一ランナー上で同じリリースがキャッシュ済みの場合は再ダウンロードを省略する．旧形式の空の完了マーカーがある場合は，初回のみ再ダウンロードしてタグを記録する．
- 配置先ディレクトリは `GITHUB_PATH` に追加されるため，後続のステップから `astra` コマンドを直接実行できる．
- セットアップ完了時に `astra --version` を実行して動作を確認する．

## ライセンス

本アクションのライセンスについては [LICENSE](./LICENSE) を参照されたい．

## 更新履歴

変更内容の一覧は [CHANGELOG](./CHANGELOG.md) を参照されたい．
