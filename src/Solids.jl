#=
With the 2020 addition of the "Symbols for Legacy Computing" to Unicode, we can
draw shapes. These characters have a subdivision grid of $2 \times 3$.
Considering that we will be drawing filled contours, the level-set can
enter/exit a character on 10 different positions. I numbered these positions
clock-wise from 0 to 9.

```
  1     2     3
   +----+----+
   |    |    |
10 +----+----+ 4
   |    |    |
 9 +----+----+ 5
   |    |    |
   +----+----+
  8     7     6
```

With a clock-wise orientation around the solid shape, we enter and exit
characters. Per character we need to know which glyph to use given the entry
and exit point.
=#

const FULL_BLOCK = '█'
const EMPTY_BLOCK = '\x00'    # Replaced during rendering, not to overdraw lower layers

const GLYPHS =
[ ((1, 4), '🭍'), (( 1, 5), '🭏'), (( 1, 6), '◣'), (( 1, 7), '🭀'),
  ((2, 4), '🭌'), (( 2, 5), '🭎'), (( 2, 6), '🭐'), (( 2, 7), '▌'), (( 2, 8), '🭛'), (( 2, 9), '🭙'), (( 2, 10), '🭗'),
                                                 (( 3, 7), '🭡'), (( 3, 8), '◤'), (( 3, 9), '🭚'), (( 3, 10), '🭘'),
  ((4, 1), '🭣'), (( 4, 2), '🭢'),                 (( 4, 7), '🭟'), (( 4, 8), '🭠'), (( 4, 9), '🭜'), (( 4, 10), '🬂'),
  ((5, 1), '🭥'), (( 5, 2), '🭤'),                 (( 5, 7), '🭝'), (( 5, 8), '🭞'), (( 5, 9), '🬎'), (( 5, 10), '🭧'),
  ((6, 1), '◥'), (( 6, 2), '🭦'),                                                 (( 6, 9), '🭓'), (( 6, 10), '🭕'),
  ((7, 1), '🭖'), (( 7, 2), '▐'), (( 7, 3), '🭋'), (( 7, 4), '🭉'), (( 7, 5), '🭇'), (( 7, 9), '🭒'), (( 7, 10), '🭔'),
                 (( 8, 2), '🭅'), (( 8, 3), '◢'), (( 8, 4), '🭊'), (( 8, 5), '🭈'),
                 (( 9, 2), '🭃'), (( 9, 3), '🭄'), (( 9, 4), '🭆'), (( 9, 5), '🬭'), (( 9, 6), '🬽'), (( 9,  7), '🬼'),
                 ((10, 2), '🭁'), ((10, 3), '🭂'), ((10, 4), '🬹'), ((10, 5), '🭑'), ((10, 6), '🬿'), ((10,  7), '🬾') ]

function get_glyph(entry::Int, exit::Int)
    glyph_map = Dict(a => b for (a, b) in GLYPHS)
    if (entry, exit) ∈ keys(glyph_map)
        glyph_map[(entry, exit)]
    else
        entry == 1 && exit >= 8 && return EMPTY_BLOCK
        exit > entry && return FULL_BLOCK
        exit == 1 && entry >= 8 && return FULL_BLOCK
        EMPTY_BLOCK
    end
end

@enum Direction UP RIGHT DOWN LEFT

#=
The WALK_MAP tells us where we go next. We leave a cell at sub-character
position <i>, given that <i> is included in the superlevel set or not.
Suppose we leave at pos 6 (lower right corner), depending on whether
that corner is part of the superlevel set, we need to go to the cell
to the right, or to the one below. This map also tells us what the
entry point is for the next cell.
=#
const WALK_MAP =
    [ (( 1, false), (   UP, 8)), (( 1, true), ( LEFT, 3))
    , (( 2, false), (   UP, 7)), (( 2, true), (   UP, 7))
    , (( 3, false), (RIGHT, 1)), (( 3, true), (   UP, 6))
    , (( 4, false), (RIGHT,10)), (( 4, true), (RIGHT,10))
    , (( 5, false), (RIGHT, 9)), (( 5, true), (RIGHT, 9))
    , (( 6, false), ( DOWN, 3)), (( 6, true), (RIGHT, 8))
    , (( 7, false), ( DOWN, 2)), (( 7, true), ( DOWN, 2))
    , (( 8, false), ( LEFT, 6)), (( 8, true), ( DOWN, 1))
    , (( 9, false), ( LEFT, 5)), (( 9, true), ( LEFT, 5))
    , ((10, false), ( LEFT, 4)), ((10, true), ( LEFT, 4)) ]

#=
Position of each point on the boundary of the character. This assumes
a 1:2 aspect ratio for the terminal cells.
=# 
const RING_POS =
    [ 0.0 0.0; 0.25 0.0; 0.5 0.0; 0.5 0.333; 0.5 0.667;
      0.5 1.0; 0.25 1.0; 0.0 1.0; 0.0 0.667; 0.0 0.333 ]

#=
Positions in between the boundary points. If we detect a sign change
between any of these points, that decides our entry and exit points
for the cell.
=#
const SCAN_RING =
    [ 0.125 0.0; 0.375 0.0; 0.5 0.167; 0.5 0.5; 0.5 0.833;
      0.375 1.0; 0.125 1.0; 0.0 0.833; 0.0 0.5; 0.0 0.167 ]

"""     filled_contour(func::Function, width::Int, height::Int)

Returns a `Matrix{Char}` with size `[width,height]`. The characters will be
filled where `func(i,j) > 0` for `i in [1:width], j in [1:height]`.

Characters that are completely empty are given the value `'\x00'`.

On the boundaries, Unicode "Symbols for Legacy Computing" are used to match the
true contour as close as possible.
"""
function filled_contour(func::Function, width::Int, height::Int)
    walk_map = Dict{Tuple{Int,Bool}, Tuple{Direction, Int}}(a => b for (a, b) in WALK_MAP)
    result = fill('\x7f', (width, height))   # fill with special value

    # First pass: check for completely submerged or completely above ground
    # cells
    for j in 1:height
        for i in 1:width
            x::Float64 = i / 2.0
            y::Float64 = j

            f0 = func(x, y)
            f2 = func(x + 0.5, y)
            f7 = func(x, y + 1.0)
            f5 = func(x + 0.5, y + 1.0)

            if f0 >= 0.0 && f2 >= 0.0 && f7 >= 0.0 && f5 >= 0.0
                result[i,j] = FULL_BLOCK; continue;
            end
            if f0 <= 0.0 && f2 <= 0.0 && f7 <= 0.0 && f5 <= 0.0
                result[i,j] = EMPTY_BLOCK; continue;
            end
        end
    end

    # Second pass: check for remaining '\x7f' values, and trace countours by
    # walking along a path that should logically cover the contour. If we
    # encounter an 'impossible' point (maybe due to round-off), we have the
    # stop-gap measure of computing the sum of the sub-cell points and making
    # the cell filled or empty based on that result.
    function find_entry(p, q)
        x = Float64[p / 2.0, q]
        w = func((x .+ SCAN_RING[10,:])...)
        for i in 1:10
            z = func((x .+ SCAN_RING[i,:])...)
            w > 0 && z < 0 && return i
            w = z
        end
        nothing
    end

    function find_exit(p, q)
        x = Float64[p / 2.0, q]
        w = func((x .+ SCAN_RING[10,:])...)
        for i in 1:10
            z = func((x .+ SCAN_RING[i,:])...)
            if w < 0 && z > 0
                incl = func((x .+ RING_POS[i,:])...) > 0
                return (i, incl)
            end
            w = z
        end
        nothing
    end

    function f_sum(p, q)
        x = Float64[p / 2.0, q]
        z = 0.0
        for a in eachrow(RING_POS)
            z += func((x .+ a)...)
        end
        z
    end

    function scan_cell(i, j)
        result[i, j] != '\x7f' && return
        possible_entry = find_entry(i, j)
        if isnothing(possible_entry)
            z = f_sum(i, j)
            result[i,j] = z > 0 ? FULL_BLOCK : EMPTY_BLOCK
            return
        end

        p = i; q = j; entry = possible_entry
        while true
            possible_exit = find_exit(p, q)
            if !isnothing(possible_exit)
                (exit, incl) = possible_exit
                result[p, q] = get_glyph(entry, exit)
                (dir, new_entry) = walk_map[(exit, incl)]
                entry = new_entry
                if dir == UP
                    q -= 1
                elseif dir == RIGHT
                    p += 1
                elseif dir == DOWN
                    q += 1
                else
                    p -= 1
                end
            else
                z = f_sum(p, q)
                result[p, q] = z > 0 ? FULL_BLOCK : EMPTY_BLOCK
                return
            end
            if p > width || q > height || p < 1 || q < 1
                return
            end
            if result[p,q] != '\x7f'
                return
            end
        end
    end

    for j in 1:height, i in 1:width
        scan_cell(i, j)
    end
    result
end

function example()
    himmelblau(x, y) = (x*x + y - 11.0)^2 + (x + y*y - 7.0)^2
    size = [51, 25]
    levels = [400.0, 150.0, 80.0, 30.0]

    print("\x1b[2J\x1b[1;1H\x1b[41m")
    for l in 1:size[2]
        println(" "^size[1])
    end
    for (k, level) in enumerate(levels)
        pic = filled_contour(
            (x, y) -> - himmelblau(x/2.0 - 6.5, -y/2.0 + 6.01) + level,
            size...)
        print("\x1b[2;1H\x1b[4$(k);3$(k+1)m")
        for l in eachcol(pic)
            println(join(l .|> c -> c == '\x00' ? "\x1b[C" : "$c"))
        end
    end
    println("\x1b[m")
end
