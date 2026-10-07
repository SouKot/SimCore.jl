using Documenter
using SimCore

makedocs(
    sitename = "SimCore.jl",
    authors = "Sourabh Kotnala <sauravkotnala@gmail.com>",
    modules = [SimCore],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://SouKot.github.io/SimCore.jl",
        sidebar_sitename = true,
    ),
    pages = [
        "Home" => "index.md",
        "Architecture & ECS" => "architecture.md",
        "Warmup Detection" => "warmup.md",
        "Statistics Pipeline" => "pipeline.md",
        "Output Analysis" => "analysis.md",
        "Hardware Acceleration" => "gpu.md",
        "API Reference" => "api.md",
    ],
    checkdocs = :exports,
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(
    repo = "github.com/SouKot/SimCore.jl.git",
    devbranch = "main",
    push_preview = true,
)
