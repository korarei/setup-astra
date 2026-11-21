# Changelog

## [1.0.0] - 2026-11-22

### Added

- `korarei/AviUtl2_Astra` (`v0.7.0` 以降) のリリースバイナリをセットアップする Composite Action (`korarei/setup-astra@v1`) を追加．
- Windows (`x64` / `ARM64`) および Linux (`x64`) ランナーに対応．
- `version` 入力によるバージョン指定 (`latest`，厳密指定，部分指定・ワイルドカード，SemVer 範囲指定) に対応．
- `token` 入力 (`${{ github.token }}` 既定) による GitHub Releases API リクエストの認証に対応．
- `RUNNER_TOOL_CACHE` を利用したツールキャッシュ，および `GITHUB_PATH` への自動登録に対応．
- インストール結果を参照できる出力 (`version`・`tag`・`path`) を追加．

[1.0.0]: https://github.com/korarei/setup-astra/releases/tag/v1.0.0
