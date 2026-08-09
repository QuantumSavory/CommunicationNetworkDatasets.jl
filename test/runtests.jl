using ParallelTestRunner
using Pkg

const ISOLATED_TEST_PROJECTS = Dict(
    "jet" => normpath(joinpath(@__DIR__, "projects", "jet")),
    "tyler" => normpath(joinpath(@__DIR__, "projects", "tyler")),
)

args = isempty(ARGS) ? ["general"] : ARGS
isolated_project =
    length(args) == 1 ? get(ISOLATED_TEST_PROJECTS, only(args), nothing) : nothing

if isempty(ARGS)
    @info "No test arguments provided; defaulting to `general` tests."
end

if isolated_project === nothing
    testsuite = find_tests(@__DIR__)
    filter!(testsuite) do (name, _)
        endswith(name, "_tests")
    end

    using CommunicationNetworkDatasets
    runtests(CommunicationNetworkDatasets, args; testsuite)
else
    @info "Routing to isolated test project." suite=only(args) project=isolated_project
    Pkg.activate(isolated_project)
    Pkg.instantiate()
    include(joinpath(isolated_project, "runtests.jl"))
end
