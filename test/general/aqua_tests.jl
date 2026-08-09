using Test

@testset "Aqua package checks" begin
    using Aqua
    using CommunicationNetworkDatasets

    Aqua.test_all(CommunicationNetworkDatasets)
end
