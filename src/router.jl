include("trie.jl")
include("handler.jl")


const GET     = "GET"
const POST    = "POST"
const PUT     = "PUT"
const PATCH   = "PATCH"
const DELETE  = "DELETE"
const OPTIONS = "OPTIONS"

mutable struct Router
    routes::Dict{String,Trie{Handler}}
end

function Router()
    Dict{String,Trie{Handler}}(
        GET     => Trie{Handler}(),
        POST    => Trie{Handler}(),
        PUT     => Trie{Handler}(),
        PATCH   => Trie{Handler}(),
        DELETE  => Trie{Handler}(),
        OPTIONS => Trie{Handler}(),
    ) |> Router
end


function (router::Router)(handler::Function, path::AbstractString; method = GET)
    !isvalidpath(path) && error("Invalid path: $path")
    routes = router.routes[method]
    routes[path] = Handler(handler)
    @assert has_handler(routes, path)
    path
end


function isvalidpath(path::AbstractString)
    # TODO this isn't the most robust will let things like "//" pass
    re = r"^[/.:a-zA-Z0-9-]+$"
    m = match(re, path)
    m !== nothing && m.match == path
end