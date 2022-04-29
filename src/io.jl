using JET.JETInterface
using Base.Core
using StructTypes
import JET:
    JET,
    @invoke,
    isexpr


const CC = Core.Compiler

# avoid kwargs in write due as it makes the analysis more complicated
# https://github.com/JuliaLang/julia/issues/9551
# https://discourse.julialang.org/t/untyped-keyword-arguments/24228
# https://discourse.julialang.org/t/closure-over-a-function-with-keyword-arguments-while-keeping-access-to-the-keyword-arguments/15574

function write(stream::Stream, data::Number, status_code = ResponseCodes.Default())
    Base.write(stream, string(data))
    HTTP.setstatus(stream, Int(status_code))
end

function write(stream::Stream, data::NamedTuple, status_code = ResponseCodes.Default())
    JSON3.write(stream ,data)
    HTTP.setstatus(stream, Int(status_code))
end

function write(stream::Stream, data::AbstractDict, status_code = ResponseCodes.Default())
    JSON3.write(stream ,data)
    HTTP.setstatus(stream, Int(status_code))
end

function write(stream::Stream, data::T, status_code = ResponseCodes.Default()) where T
    if StructTypes.StructType(T) == StructTypes.NoStructType()
        error("Unsure how to write type $T to stream")
    else
        JSON3.write(stream ,data)
    end
    HTTP.setstatus(stream, Int(status_code))
end

function write(stream::Stream, headers::Pair, status_code = ResponseCodes.Default())
    HTTP.setheader(stream, headers)
end

# allows for easier testing
function write(stream::IOBuffer, data, status_code = ResponseCodes.Default())
    Base.write(stream, data)
end

function read(stream, body::Body{T}) where T
	try
		JSON3.read(stream, T)
	catch e
		@debug "Failed to convert body into $T"
		rethrow(e)
	end
end

function convert_numbers!(data::AbstractDict, T)
	for (k, t) in zip(fieldnames(T), fieldtypes(T))
		if	t <: Number
			data[k] = parse(t, data[k])
		end
	end
	data
end

function read(stream, query::Query{T}) where T
	try
		q::Dict{Symbol, Any} = Dict(Symbol(k) => v for (k,v) in queryparams(URI(stream.message.target)))
		convert_numbers!(q, T)
		StructTypes.constructfrom(T, q)
	catch e
		@debug "Failed to convert query into $T"
		rethrow(e)
	end
end

function read(stream, hs::Headers{T}) where T
	fields = fieldnames(T)
	d = Dict()

	for i in fields
		h = headerize(i)
		if HTTP.hasheader(stream, h)
			d[i] = HTTP.header(stream, h)
		else
			d[i] = missing
		end
	end

	try
		convert_numbers!(d, T)
		StructTypes.constructfrom(T, d)
	catch e
		rethrow(e)
	end
end

struct DispatchAnalyzer{T} <: AbstractAnalyzer
    state::AnalyzerState
    opts::BitVector
    frame_filter::T
    __cache_key::UInt
end


function DispatchAnalyzer(;
    ## a predicate, which takes `CC.InfernceState` and returns whether we want to analyze the call or not
    frame_filter = x::Core.MethodInstance->true,
    jetconfigs...)
    state = AnalyzerState(; jetconfigs...)
    ## we want to run different analysis with a different filter, so include its hash into the cache key
    cache_key = state.param_key
    cache_key = hash(frame_filter, cache_key)
    return DispatchAnalyzer(state, BitVector(), frame_filter, cache_key)
end

## AbstractAnalyzer API requirements
JETInterface.AnalyzerState(analyzer::DispatchAnalyzer)                          = analyzer.state
JETInterface.AbstractAnalyzer(analyzer::DispatchAnalyzer, state::AnalyzerState) = DispatchAnalyzer(state, analyzer.opts, analyzer.frame_filter, analyzer.__cache_key)
JETInterface.ReportPass(analyzer::DispatchAnalyzer)                             = DispatchAnalysisPass()
JETInterface.get_cache_key(analyzer::DispatchAnalyzer)                          = analyzer.__cache_key

struct DispatchAnalysisPass <: ReportPass end
## ignore all reports defined by JET, since we'll just define our own reports
(::DispatchAnalysisPass)(T::Type{<:InferenceErrorReport}, @nospecialize(_...)) = return


function CC.finish!(analyzer::DispatchAnalyzer, frame::Core.Compiler.InferenceState)

    caller = frame.result

    ## get the source before running `finish!` to keep the reference to `OptimizationState`
    src = caller.src
    ## run `finish!(::AbstractAnalyzer, ::CC.InferenceState)` first to convert the optimized `IRCode` into optimized `CodeInfo`
    ret = @invoke CC.finish!(analyzer::AbstractAnalyzer, frame::CC.InferenceState)

    if analyzer.frame_filter(frame.linfo)
		ReportPass(analyzer)(IoReport, analyzer, caller, src)
    end

    return ret
end

@reportdef struct IoReport <: InferenceErrorReport slottypes end

JETInterface.get_msg(::Type{IoReport}, args...) =
    return "detected io" #: signature of this MethodInstance

function (::DispatchAnalysisPass)(::Type{IoReport}, analyzer::DispatchAnalyzer, caller::CC.InferenceResult, opt::CC.OptimizationState)
	(;src, linfo, slottypes, sptypes) = opt

	fn = get(slottypes, 1, nothing)
	if fn == Core.Const((@__MODULE__).read)

        add_new_report!(analyzer, caller, IoReport(caller, slottypes))

    elseif fn == Core.Const((@__MODULE__).write)

        status_code = get(slottypes, 4, nothing)
        if !(status_code isa Core.Const)
            return
        end

        data = get(slottypes, 3, nothing)
        if !(data isa Type)
            return
        end

        add_new_report!(analyzer, caller, IoReport(caller, slottypes))
    end
end

# TODO: needs another instance to handle Core.Const
extract_type(::Type{T}) where T = T

function handler_writes(@nospecialize(handler))
	calls = JET.report_call(handler, Tuple{Stream}, analyzer=DispatchAnalyzer ) 
	reports = JET.get_reports(calls)
    fn = Core.Const((@__MODULE__).write)
    filter!(x -> x.slottypes[1] == fn, reports)
	l = map(reports) do r
		res_type = r.slottypes[3]
		res_code = r.slottypes[4].val
        # @debug "writes" type=res_type code=res_code
		(extract_type(res_type), res_code)
	end
end


function handler_reads(@nospecialize(handler))
	calls = JET.report_call(handler, Tuple{Stream}, analyzer=DispatchAnalyzer ) 
	reports = JET.get_reports(calls)
    fn = Core.Const((@__MODULE__).read)
    filter!(x -> x.slottypes[1] ==  fn, reports)
	l = map(reports) do r
		res_type = r.slottypes[3]
        @info r.slottypes
        @info res_type
        # @debug "writes" type=res_type code=res_code
		(extract_type(res_type))
	end
end

handler_reads(handler::AbstractHandler) = handler_reads(handler.fn)

