using PooledArrays
using Test
using JSON3
using ExpandNestedData
using TypedTables
using DataStructures: OrderedRobinDict

EN = ExpandNestedData

fieldequal(v1, v2) = (v1==v2) isa Bool ? v1==v2 : false
fieldequal(::Nothing, ::Nothing) = true
fieldequal(::Missing, ::Missing) = true
fieldequal(a1::AbstractArray, a2::AbstractArray) = length(a1) == length(a2) && fieldequal.(a1,a2) |> all
function fieldsequal(o1, o2)
    for name in fieldnames(typeof(o1))
        prop1 = getproperty(o1, name)
        prop2 = getproperty(o2, name)
        if !fieldequal(prop1, prop2)
            println("Didn't match on $name. Got $prop1 and $prop2")
            return false
        end
    end
    return true
end
function fieldsequal(o1::NamedTuple, o2::NamedTuple)
    for name in keys(o1)
        prop1 = getindex(o1, name)
        prop2 = getindex(o2, name)

        if prop1 isa NamedTuple && prop2 isa NamedTuple
            return fieldsequal(prop1, prop2)
        end
        if !fieldequal(prop1, prop2)
            println("Didn't match on $name. Got $prop1 and $prop2")
            return false
        end
    end
    return true
end

function get_rows(t, fields, len)
    return [
        Dict(
            f => t[f][i]
            for f in fields
        )
        for i in 1:len
    ]
end
function unordered_equal(t1, t2)
    fields = keys(t1)
    len = length(t1[1])
    Set(get_rows(t1, fields,len)) == Set(get_rows(t2, fields,len))
end
@testset "ExpandNestedData" begin

    @testset "Internals" begin
        @testset "NestedIterators and ColumnSets" begin
            iter1 = ExpandNestedData.NestedIterator([1,2])
            @test [1,2] == collect(iter1)
            @test [1,2,1,2] == collect(ExpandNestedData.cycle(iter1, 2))
            @test [1,1,2,2] == collect(ExpandNestedData.repeat_each(iter1, 2))
            @test [1,2,1,2] == collect(ExpandNestedData.vcat(iter1, iter1))
            col_set = ExpandNestedData.ColumnSet(
                ExpandNestedData.NameID(2) => ExpandNestedData.NestedIterator([3,4,5,6]),
                ExpandNestedData.NameID(1) => ExpandNestedData.NestedIterator([1,2]),
            )
            @test collect(keys(col_set)) == [ExpandNestedData.NameID(1),ExpandNestedData.NameID(2)]
            col_set2 = ExpandNestedData.ColumnSet(
                ExpandNestedData.NameID(1) => ExpandNestedData.NestedIterator([1,2,1,2]),
                ExpandNestedData.NameID(2) => ExpandNestedData.NestedIterator([3,4,5,6]),
            )
            @test isequal( ExpandNestedData.cycle_columns_to_length!(col_set), col_set2)
            
            # popping columns
            @test ExpandNestedData.get_first_key(col_set) == ExpandNestedData.NameID(1)
            default_col = pop!(col_set, ExpandNestedData.NameID(3), ExpandNestedData.NestedIterator([1]))
            @test default_col == ExpandNestedData.NestedIterator([1,1,1,1])
            @test isequal(col_set, col_set2)
            popped_col = pop!(col_set, ExpandNestedData.NameID(2), ExpandNestedData.NestedIterator([1]))
            @test popped_col == ExpandNestedData.NestedIterator([3,4,5,6])
            @test collect(keys(col_set)) == [ExpandNestedData.NameID(1)]

            # column length 
            @test ExpandNestedData.get_total_length([col_set, col_set2]) == 8
            @test ExpandNestedData.column_length(ExpandNestedData.repeat_each_column!(col_set, 2)) == 8

            # column set manager
            csm = ExpandNestedData.ColumnSetManager()
            cs = ExpandNestedData.get_column_set(csm)
            @test isequal(cs, ExpandNestedData.ColumnSet())
            ExpandNestedData.free_column_set!(csm, cs)
            @test !isempty(csm.column_sets)
            cs = ExpandNestedData.get_column_set(csm)
            @test isempty(csm.column_sets)

            cs[ExpandNestedData.NameID(3)] = ExpandNestedData.NestedIterator()
            cs[ExpandNestedData.NameID(1)] = ExpandNestedData.NestedIterator()
            @test collect(keys(cs)) == [ExpandNestedData.NameID(1),ExpandNestedData.NameID(3)]

            name = :test_name
            id = ExpandNestedData.get_id(csm, name)
            @test id == ExpandNestedData.NameID(2)
            @test id == ExpandNestedData.get_id(csm, name)
            @test name == ExpandNestedData.get_name(csm, id)
            field_path = (name,)
            id_path = (id,)
            id_for_path = ExpandNestedData.get_id(csm, id_path)
            @test id_for_path == ExpandNestedData.get_id_for_path(csm, field_path)
            
            # NameLinks 
            top = ExpandNestedData.top_level
            l = ExpandNestedData.NameList(csm, top, id)
            id_for_tuple_from_list = ExpandNestedData.get_id(csm, l)
            @test id_for_tuple_from_list == id_for_path
            @test ExpandNestedData.ColumnSetManagers.reconstruct_field_path(csm, id_for_tuple_from_list) == field_path
            
            # Rebuild ColumnSet
            raw_cs = ExpandNestedData.ColumnSet(id_for_path => ExpandNestedData.NestedIterator([1]))
            @test OrderedRobinDict((name,) => ExpandNestedData.NestedIterator([1])) == ExpandNestedData.build_final_column_set(csm, raw_cs)
        end

        @testset "ColumnDefinitions and PathGraph" begin
            @test fieldsequal(ColumnDefinition((:a,)), ColumnDefinition([:a]))
            coldef = ColumnDefinition((:a,:b), Dict(); pool_arrays=false, name_join_pattern = "^")
            @test coldef == ColumnDefinition((:a,:b), Symbol("a^b"), missing, false)
            @test ExpandNestedData.current_path_name(coldef, 2) == :b
            @test collect(ExpandNestedData.make_column_def_child_copies([coldef], :a, 1)) == [coldef]
        end

        @testset "Utils" begin
            @test ExpandNestedData.all_eltypes_are_values(Vector{Union{Int64, String, Float64}})
            @test !ExpandNestedData.all_eltypes_are_values(Vector{Union{Int64, String, AbstractFloat}})
            @test !ExpandNestedData.all_eltypes_are_values(Vector{Union{Dict, String}})
            d = Dict(:a => 1, :b => 2)
            @test ExpandNestedData.get_names(d) == keys(d)
            struct _T_
                a
            end

            @test collect(ExpandNestedData.get_names(_T_(1))) == collect(fieldnames(_T_))
            @test ExpandNestedData.get_value(d, :a, 3) == 1
            @test ExpandNestedData.get_value(d, :c, 3) == 3
            @test ExpandNestedData.get_value(_T_(1), :a, 3) == 1
            @test ExpandNestedData.join_names((:a,1,"hi"), ".") == Symbol("a.1.hi")

        end


    end

    

    # end

    # @testset "DataStructure Internals" begin
    #     d = OrderedRobinDict(:a => 1, :b => 2)
    #     k = d.keys
    #     @test k isa Vector{Symbol}
    #     @test k[2] == :b
    # end


    # # Source Data
    # simple_test_body = JSON3.read("""
    # {"data" : [
    #     {"E" : 7, "D" : 1},
    #     {"E" : 8, "D" : 2}
    # ]}""")
    # expected_simple_table = (data_E=[7,8], data_D=[1,2])

    # test_body_str = """
    # {
    #     "a" : [
    #         {"b" : 1, "c" : 2},
    #         {"b" : 2},
    #         {"b" : [3, 4], "c" : 1},
    #         {"b" : []}
    #     ],
    #     "d" : 4
    # }
    # """
    # test_body = JSON3.read(test_body_str)

    # struct InternalObj
    #     b
    #     c
    # end
    # struct MainBody
    #     a::Vector{InternalObj}
    #     d
    # end
    # struct_body = JSON3.read(test_body_str, MainBody)

    # heterogenous_level_test_body = Dict(
    #         :data => [
    #             Dict(:E => 8),
    #             5
    #             ]
    #         )

    # @testset "Unguided Expand" begin
    #     actual_simple_table = EN.expand(simple_test_body)
    #     @test unordered_equal(actual_simple_table, expected_simple_table)
    #     @test eltype(actual_simple_table.data_D) == Int64

    #     # Expanding Arrays
    #     @test begin
    #         actual_expanded_table = EN.expand(test_body)
    #         expected_table_expanded = (
    #             a_b=[1,2,3,4,missing], 
    #             a_c=[2,missing,1,1, missing], 
    #             d=[4,4,4,4,4])
    #         unordered_equal(actual_expanded_table, expected_table_expanded)
    #     end

    #     # Using struct of struct as input
    #     @test begin
    #         expected_table_expanded = (
    #             new_column=[1,2,3,4,nothing], 
    #             a_c=[2,nothing,1,1, nothing], 
    #             d=[4,4,4,4,4])
    #             unordered_equal(
    #             EN.expand(struct_body; default_value=nothing, column_names= Dict((:a, :b) => :new_column)), 
    #             expected_table_expanded)
    #     end
    #     @test (typeof(EN.expand(struct_body; pool_arrays=true, lazy_columns=false).d) == 
    #         typeof(PooledArray(Int64[])))
        
    #     @test fieldsequal((EN.expand(struct_body; column_style=:nested) |> rows |> last), (a=(b=1,c=2), d=4))

    #     @test unordered_equal(EN.expand(heterogenous_level_test_body), (data = [5], data_E = [8]))

    #     empty_dict_field = Dict(
    #         :a => Dict(),
    #         :b => 5
    #     )
    #     @test unordered_equal(EN.expand(empty_dict_field), (b = [5],))

    #     @test begin
    #         two_layer_deep = Dict(
    #             :a => Dict(
    #                 :b => Dict(
    #                     :c => 1,
    #                     :d => 2,
    #                 )
    #             )
    #         )
    #         unordered_equal(EN.expand(two_layer_deep), (a_b_c = [1], a_b_d = [2]))
    #     end
    # end


    # @testset "Configured Expand" begin
    #     columns_defs = [
    #         EN.ColumnDefinition((:d,)),
    #         EN.ColumnDefinition((:a, :b)),
    #         EN.ColumnDefinition((:a, :c); name_join_pattern = "?_#"),
    #         EN.ColumnDefinition((:e, :f); default_value="Missing branch")
    #         ]
    #     expected_table = NamedTuple((:d=>[4,4,4,4,4], :a_b=>[1,2,3,4, missing], Symbol("a?_#c")=>[2,missing,1,1, missing], 
    #         :e_f => repeat(["Missing branch"], 5))
    #     )
    #     @test unordered_equal(EN.expand(test_body, columns_defs), expected_table)
    #     @test fieldsequal(
    #         EN.expand(test_body, columns_defs; column_style=:nested) |> rows |> last, 
    #         (d=4, a=(b = 1, c = 2), e = (f="Missing branch",))
    #     )
    #     columns_defs = [
    #         EN.ColumnDefinition((:data,)),
    #         EN.ColumnDefinition((:data, :E))
    #     ]
    #     @test unordered_equal(EN.expand(heterogenous_level_test_body, columns_defs), (data = [5], data_E = [8]))

    # end

    # @testset "superficial options" begin
    #     # Expanding Arrays
    #     actual_expanded_table = EN.expand(test_body; name_join_pattern = "?_#")
    #     @test begin
    #         expected_table_expanded = NamedTuple((
    #             Symbol("a?_#b")=>[1,2,3,4,missing], 
    #             Symbol("a?_#c")=>[2,missing,1,1, missing], 
    #             :d=>[4,4,4,4,4]))
    #         unordered_equal(actual_expanded_table, expected_table_expanded)
    #     end
    # end
end
