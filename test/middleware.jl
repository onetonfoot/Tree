using Bonsai
using Bonsai: combine_middleware, match_middleware, Middleware
using URIs
using Dates

t = false
c = false

@testset "combine_middleware" begin

	function timer(stream, next)
		x = now()
		next(stream)
		elapsed = x - now()
		global t
		t = true
	end

	function cors(stream, next)
		next(stream)
		global c
		c = true
	end

	fn = combine_middleware([timer, cors ])
	fn(nothing)
	@test c && t
end

@testset "all!" begin
	r = Router()
	function f(stream, next) end
	all!(r, "*" , Middleware(f))
	@test all(length.(values(r.middleware)) .== 1)
end

@testset "match_middleware" begin
	r = Router()
	function f(stream, next) end
	all!(r, "*" , Middleware(f))
	@test length(match_middleware(r, GET, URI("/")))== 1
end

@testset "single route" begin
	r = Router()
	function fn1(stream, next) end
	function fn2(stream) end
	get!(r, "*" , fn1)
	length(r.middleware[GET]) == 1
	get!(r, "*" , fn2)
	length(r.paths[GET]) == 1
end