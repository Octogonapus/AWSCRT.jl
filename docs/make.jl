using AWSMQTT
using Documenter

DocMeta.setdocmeta!(AWSMQTT, :DocTestSetup, :(using AWSMQTT); recursive=true)

makedocs(;
    modules=[AWSMQTT],
    authors="Octogonapus <firey45@gmail.com> and contributors",
    repo="https://github.com/Octogonapus/AWSMQTT.jl/blob/{commit}{path}#{line}",
    sitename="AWSMQTT.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://Octogonapus.github.io/AWSMQTT.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/Octogonapus/AWSMQTT.jl",
    devbranch="main",
)
