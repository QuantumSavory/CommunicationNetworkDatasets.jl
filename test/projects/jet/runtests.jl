using CommunicationNetworkDatasets
using JET
using Test
import CSV
import DataFrames

@testset "JET package-owned reports" begin
    result = JET.report_package(
        CommunicationNetworkDatasets;
        target_modules=(CommunicationNetworkDatasets,),
        ignored_modules=(JET.AnyFrameModule(CSV), JET.AnyFrameModule(DataFrames)),
        toplevel_logger=nothing,
    )
    @test isempty(JET.get_reports(result))
end
