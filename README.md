<p align="center">
  <img src="docs/images/banner.png" alt="DocuFind" width="100%">
</p>

<h3 align="center">Find anything on your Mac by describing it.</h3>
<p align="center">Documents, photos and recordings, searched by meaning, right on your Mac.</p>

<p align="center">
  <a href="https://github.com/Theodb/DocuFind/releases/latest"><img alt="Download for Mac" src="https://img.shields.io/badge/Download_for_Mac-0A84FF?style=for-the-badge&logo=apple&logoColor=white"></a>
</p>
<p align="center"><sub>macOS 15 or later · Running on Apple silicon · Free and open source</sub></p>
<p align="center">
  <a href="https://arxiv.org/pdf/2604.02045"><img alt="Paper on arXiv" src="https://img.shields.io/badge/Paper-arXiv_2604.02045-B31B1B?style=for-the-badge&labelColor=555555&logo=arxiv&logoColor=B31B1B"></a>
  <a href="https://huggingface.co/BidirLM"><img alt="BidirLM on Hugging Face" src="https://img.shields.io/badge/Hugging_Face-BidirLM--Omni-FFD21E?style=for-the-badge&labelColor=555555&logo=huggingface&logoColor=FFD21E"></a>
</p>

https://github.com/user-attachments/assets/bee7b1ba-5f19-4a75-aa14-19febc69ce0a

# DocuFind

You remember *what* it was, not *where* you put it. Type "that sunset at the beach", "the invoice from the plumber" or "the song with the saxophone", and DocuFind finds it. Everything happens on your Mac with the open [BidirLM-Omni](https://huggingface.co/BidirLM/BidirLM-Omni-2.5B-Embedding) model: no cloud, no account, no peeking.

## What it does

- **One search for everything**: documents, PDFs (even scanned ones), photos and recordings
- **Drop it or record it**: search with a file, or with a few seconds of sound from the microphone
- **Pops up anywhere**: press **⌥ Space** in any app for a floating search bar
- **Straight to the good part**: recordings play from the matching moment, PDFs open at the right page
- **Exact words too**: invoice numbers, names, and text inside screenshots
- **Fast and fresh**: about 50 photos a minute and an hour of recordings in under a minute on an M4, and new files show up on their own

## The model behind it

DocuFind runs on [BidirLM-Omni-2.5B-Embedding](https://huggingface.co/BidirLM/BidirLM-Omni-2.5B-Embedding), our own open embedding model from BidirLM at Diabolocom Research × CentraleSupélec. It places text, images and audio in one shared space, so a few words can find a photo or a recording. It was released by [Nicolas Boizard](https://www.linkedin.com/in/nicolas-boizard/), [Théo Deschamps-Berger](https://www.linkedin.com/in/theodb), Hippolyte Gisserot-Boukhlef, Céline Hudelot and Pierre Colombo ([paper](https://arxiv.org/abs/2604.02045)).

| | Score | Among models under 4B parameters |
|---|---|---|
| Audio (MAEB) | 45.2 | #1 |
| Images (MIEB) | 58.1 | #1 with open training data |
| Text (MTEB) | 63.1 | #2 with open training data |

<sub>Scores average all tasks (MTEB Multilingual v2, MIEB lite, MAEB beta), from the paper's snapshot of 30 March 2026. See the [MTEB leaderboard](https://huggingface.co/spaces/mteb/leaderboard).</sub>

## Runs on the Neural Engine

DocuFind runs the whole model, for text, photos and recordings, on your Mac's Neural Engine, Apple's chip for machine learning. For that, BidirLM-Omni was converted to Core ML as part of DocuFind; the converted model is published at [BidirLM-Omni-2.5B-Embedding-CoreML](https://huggingface.co/BidirLM/BidirLM-Omni-2.5B-Embedding-CoreML), so there is no PyTorch to install.

- **About twice as fast on average** as the original model on the Apple GPU: text 2.7×, photos 1.9×, recordings 1.7× on an M4
- **Never waiting on files**: the next photos and recordings are read while the Neural Engine works, so indexing keeps it busy (iPhone photos index 2.2× faster than reading them one by one)
- **The same results**: every vector agrees with the original model at 0.997 or better, and searches find the same best match
- **The GPU stays free** for everything else you do

## Get started

You need an Apple silicon Mac with macOS 15 or later.

1. Grab the disk image from [Releases](https://github.com/Theodb/DocuFind/releases) and drag **DocuFind** into **Applications**.
2. Follow the welcome guide: it installs everything and downloads the model once (about 3.5 GB). Pick your folders, hit **Start Indexing**.

## Using it

Press **⌥ Space**, start typing. In results, **← →** hop between matches and **Space** plays a recording.

Prefer the terminal? It's there too:

```sh
docufind search "the invoice from the plumber"
docufind similar ~/Music/clip.m4a
docufind index ~/Documents/Notes      # refresh just this folder
```

Link it once:

```sh
sudo ln -sf /Applications/DocuFind.app/Contents/Helpers/docufind /usr/local/bin/docufind
```

## Your files stay yours

Indexing and search run entirely on your Mac. No account, no analytics, no remote servers. The internet is only used once, to install the runtime and download the model. Everything DocuFind knows lives in `~/Library/Application Support/DocuFind`; delete that folder and it's all gone.

## Build it yourself

```sh
git clone https://github.com/Theodb/DocuFind.git
cd DocuFind
./scripts/build.sh                 # builds ../DocuFind.app
./scripts/test-ui-helpers.sh       # Swift tests
python3 -m unittest discover -s backend/tests
```

You'll need the Xcode command-line tools. Curious how it works? See [backend/README.md](backend/README.md).

## License

[MIT](LICENSE). The model and the libraries it downloads have their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
