using AWSCRT
using Documenter

DocMeta.setdocmeta!(AWSCRT, :DocTestSetup, :(using AWSCRT); recursive = true)

makedocs(;
    modules = [AWSCRT],
    repo = "https://github.com/Octogonapus/AWSCRT.jl/blob/{commit}{path}#{line}",
    sitename = "AWSCRT.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://Octogonapus.github.io/AWSCRT.jl",
        assets = String[],
    ),
    pages = ["Home" => "index.md"],
)

deploydocs(; repo = "github.com/Octogonapus/AWSCRT.jl", devbranch = "main")
