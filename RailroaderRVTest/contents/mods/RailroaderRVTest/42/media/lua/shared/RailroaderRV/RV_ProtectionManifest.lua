-- Hard-coded, full identity and protection-class ledger for the captured RV objects.
-- Keep this list explicit: runtime code validates RV_Template against it but never derives it.
-- 1=free demolition; 2=restore after demolition; 3=demolition blocked and restored; 4=special.
local P = {}

P.FREE_DEMOLITION = 1
P.RESTORE_ONLY = 2
P.PROHIBITED = 3
P.SPECIAL = 4
P.OBJECT_COUNT = 412
P.EXPECTED_CLASS_COUNTS = { [1] = 49, [2] = 0, [3] = 363, [4] = 0 }

P.objects = {
    {templateIndex=1, x=-4, y=-6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_13", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=2, x=-4, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=3, x=-4, y=-6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=4, x=-4, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=5, x=-4, y=-5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=6, x=-4, y=-5, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=7, x=-4, y=-5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=8, x=-4, y=-5, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=9, x=-4, y=-4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=10, x=-4, y=-4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=11, x=-4, y=-4, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=12, x=-4, y=-3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_12", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=13, x=-4, y=-3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=14, x=-4, y=-3, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=15, x=-4, y=-2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=16, x=-4, y=-2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=1},
    {templateIndex=17, x=-4, y=-2, z=0, class="IsoThumpable", name="Wooden Door Frame", sprite="walls_interior_house_02_43", north=true, direction="N", state={health=300,hoppable=false,locked=false,maxHealth=300}, protectionClass=1},
    {templateIndex=18, x=-4, y=-2, z=0, class="IsoDoor", name="Wooden Door", sprite="location_restaurant_pileocrepe_01_49", north=true, direction="N", state={}, protectionClass=1},
    {templateIndex=19, x=-4, y=-1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=20, x=-4, y=-1, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_10_28", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=1},
    {templateIndex=21, x=-4, y=-1, z=0, class="IsoWindow", name="Window", sprite="fixtures_windows_metal_28", north=false, direction="N", state={health=50,hoppable=false,locked=false}, protectionClass=1},
    {templateIndex=22, x=-4, y=-1, z=0, class="IsoThumpable", name="Thumpable", sprite="furniture_seating_indoor_01_51", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=1},
    {templateIndex=23, x=-4, y=0, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=24, x=-4, y=0, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_10_24", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=1},
    {templateIndex=25, x=-4, y=0, z=0, class="IsoWindow", name="Window", sprite="fixtures_windows_metal_24", north=false, direction="N", state={health=50,hoppable=false,locked=false}, protectionClass=1},
    {templateIndex=26, x=-4, y=1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=27, x=-4, y=1, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=1},
    {templateIndex=28, x=-4, y=1, z=0, class="IsoThumpable", name="Thumpable", sprite="furniture_seating_indoor_01_51", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=1},
    {templateIndex=29, x=-4, y=2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=30, x=-4, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_41", north=true, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=31, x=-4, y=2, z=0, class="IsoWindow", name="Window", sprite="fixtures_windows_01_33", north=true, direction="N", state={health=50,hoppable=false,locked=false}, protectionClass=1},
    {templateIndex=32, x=-4, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=33, x=-4, y=2, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=34, x=-4, y=3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=35, x=-4, y=3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=36, x=-4, y=3, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=37, x=-4, y=4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=38, x=-4, y=4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=39, x=-4, y=4, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=40, x=-4, y=5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=41, x=-4, y=5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=42, x=-4, y=5, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=43, x=-4, y=6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=44, x=-4, y=6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=45, x=-4, y=6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=46, x=-4, y=7, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=47, x=-4, y=7, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=48, x=-4, y=7, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=49, x=-4, y=8, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=50, x=-4, y=8, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=51, x=-4, y=8, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=52, x=-4, y=9, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=53, x=-4, y=9, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=54, x=-4, y=9, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=55, x=-4, y=10, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=56, x=-4, y=10, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=57, x=-4, y=10, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=58, x=-4, y=11, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=59, x=-4, y=11, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=60, x=-4, y=11, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=61, x=-4, y=12, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=62, x=-4, y=12, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=63, x=-4, y=12, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=64, x=-4, y=13, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=65, x=-4, y=13, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=66, x=-4, y=13, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=67, x=-4, y=14, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=68, x=-4, y=14, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=69, x=-4, y=14, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=70, x=-4, y=15, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=71, x=-4, y=15, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=72, x=-4, y=15, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=73, x=-4, y=16, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_13", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=74, x=-4, y=16, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=75, x=-4, y=17, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=76, x=-4, y=17, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=77, x=-3, y=-6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=78, x=-3, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=79, x=-3, y=-6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=80, x=-3, y=-5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=81, x=-3, y=-4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=82, x=-3, y=-4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=83, x=-3, y=-4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=84, x=-3, y=-3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=85, x=-3, y=-3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=86, x=-3, y=-2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=87, x=-3, y=-2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=1},
    {templateIndex=88, x=-3, y=-2, z=0, class="IsoLightSwitch", name="LightSwitch", sprite="lighting_outdoor_01_40", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=89, x=-3, y=-1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=90, x=-3, y=0, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=91, x=-3, y=1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=92, x=-3, y=2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=93, x=-3, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=94, x=-3, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=95, x=-3, y=3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=96, x=-3, y=3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=97, x=-3, y=4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=98, x=-3, y=4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=99, x=-3, y=5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=100, x=-3, y=5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=101, x=-3, y=6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=102, x=-3, y=6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=103, x=-3, y=7, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=104, x=-3, y=7, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=105, x=-3, y=8, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=106, x=-3, y=8, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=107, x=-3, y=9, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=108, x=-3, y=9, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=109, x=-3, y=10, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=110, x=-3, y=10, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=111, x=-3, y=11, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=112, x=-3, y=11, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=113, x=-3, y=12, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=114, x=-3, y=12, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=115, x=-3, y=13, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=116, x=-3, y=13, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=117, x=-3, y=14, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=118, x=-3, y=14, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=119, x=-3, y=15, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=120, x=-3, y=15, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=121, x=-3, y=16, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=122, x=-3, y=17, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=123, x=-3, y=17, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=124, x=-2, y=-6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=125, x=-2, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=126, x=-2, y=-6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=127, x=-2, y=-5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=128, x=-2, y=-5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=129, x=-2, y=-5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=130, x=-2, y=-4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=131, x=-2, y=-4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_35", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=132, x=-2, y=-3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=133, x=-2, y=-2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=134, x=-2, y=-2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=1},
    {templateIndex=135, x=-2, y=-1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=136, x=-2, y=0, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=137, x=-2, y=1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=138, x=-2, y=2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=139, x=-2, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=140, x=-2, y=3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=141, x=-2, y=4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=142, x=-2, y=5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=143, x=-2, y=6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=144, x=-2, y=7, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=145, x=-2, y=8, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=146, x=-2, y=9, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=147, x=-2, y=10, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=148, x=-2, y=11, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=149, x=-2, y=12, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=150, x=-2, y=13, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=151, x=-2, y=14, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=152, x=-2, y=15, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=153, x=-2, y=15, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=154, x=-2, y=16, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=155, x=-2, y=16, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=156, x=-2, y=17, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=157, x=-2, y=17, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=158, x=-1, y=-6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=159, x=-1, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=160, x=-1, y=-6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=161, x=-1, y=-5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=162, x=-1, y=-5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=163, x=-1, y=-4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=164, x=-1, y=-3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=165, x=-1, y=-2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=166, x=-1, y=-2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=1},
    {templateIndex=167, x=-1, y=-1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=168, x=-1, y=0, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=169, x=-1, y=1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=170, x=-1, y=2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=171, x=-1, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=172, x=-1, y=3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=173, x=-1, y=4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=174, x=-1, y=5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=175, x=-1, y=6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=176, x=-1, y=7, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=177, x=-1, y=8, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=178, x=-1, y=9, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=179, x=-1, y=10, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=180, x=-1, y=11, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=181, x=-1, y=12, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=182, x=-1, y=13, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=183, x=-1, y=14, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=184, x=-1, y=15, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=185, x=-1, y=16, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=186, x=-1, y=16, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=187, x=-1, y=17, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=188, x=-1, y=17, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=189, x=0, y=-6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=190, x=0, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=191, x=0, y=-6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=192, x=0, y=-5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=193, x=0, y=-5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=194, x=0, y=-4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=195, x=0, y=-4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=196, x=0, y=-3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=197, x=0, y=-2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=198, x=0, y=-2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=1},
    {templateIndex=199, x=0, y=-2, z=0, class="IsoLightSwitch", name="LightSwitch", sprite="lighting_outdoor_01_40", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=200, x=0, y=-2, z=0, class="IsoThumpable", name="Thumpable", sprite="appliances_com_01_52", north=true, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=1},
    {templateIndex=201, x=0, y=-1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=202, x=0, y=0, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=203, x=0, y=1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=204, x=0, y=2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=205, x=0, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=206, x=0, y=3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=207, x=0, y=4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=208, x=0, y=5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=209, x=0, y=6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=210, x=0, y=7, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=211, x=0, y=8, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=212, x=0, y=9, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=213, x=0, y=10, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=214, x=0, y=11, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=215, x=0, y=12, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=216, x=0, y=13, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=217, x=0, y=14, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=218, x=0, y=15, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=219, x=0, y=15, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=220, x=0, y=15, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=221, x=0, y=16, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_37", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=222, x=0, y=16, z=0, class="IsoObject", name="Wooden Wall", sprite="walls_interior_house_02_35", north="none", direction="N", state={}, protectionClass=3},
    {templateIndex=223, x=0, y=17, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=224, x=0, y=17, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=225, x=1, y=-6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_13", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=226, x=1, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=227, x=1, y=-6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=228, x=1, y=-5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=229, x=1, y=-5, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=230, x=1, y=-4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=231, x=1, y=-4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=232, x=1, y=-3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=233, x=1, y=-3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=234, x=1, y=-2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=235, x=1, y=-2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_41", north=true, direction="N", state={canPassThrough=true,health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=1},
    {templateIndex=236, x=1, y=-2, z=0, class="IsoWindow", name="Window", sprite="fixtures_windows_01_33", north=true, direction="N", state={health=50,hoppable=false,locked=false}, protectionClass=1},
    {templateIndex=237, x=1, y=-2, z=0, class="IsoThumpable", name="Thumpable", sprite="appliances_com_01_52", north=true, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=1},
    {templateIndex=238, x=1, y=-1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=239, x=1, y=-1, z=0, class="IsoThumpable", name="Thumpable", sprite="furniture_seating_indoor_01_51", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=1},
    {templateIndex=240, x=1, y=0, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=241, x=1, y=1, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=1},
    {templateIndex=242, x=1, y=2, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_12", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=243, x=1, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=244, x=1, y=2, z=0, class="IsoThumpable", name="Wooden Door Frame", sprite="walls_interior_house_02_43", north=true, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=245, x=1, y=2, z=0, class="IsoDoor", name="Wooden Door", sprite="location_restaurant_pileocrepe_01_49", north=true, direction="N", state={}, protectionClass=1},
    {templateIndex=246, x=1, y=3, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=247, x=1, y=3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=248, x=1, y=4, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=249, x=1, y=4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=250, x=1, y=5, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=251, x=1, y=5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=252, x=1, y=6, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=253, x=1, y=6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=254, x=1, y=7, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=255, x=1, y=7, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=256, x=1, y=8, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=257, x=1, y=8, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=258, x=1, y=9, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=259, x=1, y=9, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=260, x=1, y=10, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=261, x=1, y=10, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=262, x=1, y=11, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=263, x=1, y=11, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=264, x=1, y=12, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=265, x=1, y=12, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=266, x=1, y=13, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=267, x=1, y=13, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=268, x=1, y=14, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=269, x=1, y=14, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=270, x=1, y=15, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_38", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=271, x=1, y=15, z=0, class="IsoObject", name="Wooden Wall", sprite="walls_interior_house_02_35", north="none", direction="N", state={}, protectionClass=3},
    {templateIndex=272, x=1, y=16, z=0, class="IsoObject", name="IsoObject", sprite="industry_01_13", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=273, x=1, y=16, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=274, x=1, y=17, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_33", north=true, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=275, x=1, y=17, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_37", north=true, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=276, x=2, y=-5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=277, x=2, y=-5, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=278, x=2, y=-4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=279, x=2, y=-4, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=280, x=2, y=-3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=281, x=2, y=-3, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=282, x=2, y=-2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=283, x=2, y=-1, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_10_28", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=284, x=2, y=-1, z=0, class="IsoWindow", name="Window", sprite="fixtures_windows_metal_28", north=false, direction="N", state={health=50,hoppable=false,locked=false}, protectionClass=1},
    {templateIndex=285, x=2, y=0, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_10_24", north=false, direction="N", state={health=350,hoppable=false,locked=false,maxHealth=350}, protectionClass=3},
    {templateIndex=286, x=2, y=0, z=0, class="IsoWindow", name="Window", sprite="fixtures_windows_metal_24", north=false, direction="N", state={health=50,hoppable=false,locked=false}, protectionClass=1},
    {templateIndex=287, x=2, y=1, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=288, x=2, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_35", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=289, x=2, y=2, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=290, x=2, y=2, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=291, x=2, y=3, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=292, x=2, y=3, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=293, x=2, y=4, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=294, x=2, y=4, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=295, x=2, y=5, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=296, x=2, y=5, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=297, x=2, y=6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=298, x=2, y=6, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=299, x=2, y=7, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=300, x=2, y=7, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=301, x=2, y=8, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=302, x=2, y=8, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=303, x=2, y=9, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=304, x=2, y=9, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=305, x=2, y=10, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=306, x=2, y=10, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=307, x=2, y=11, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=308, x=2, y=11, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=309, x=2, y=12, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=310, x=2, y=12, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=311, x=2, y=13, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=312, x=2, y=13, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=313, x=2, y=14, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=314, x=2, y=14, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=315, x=2, y=15, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=316, x=2, y=15, z=0, class="IsoThumpable", name="Thumpable", sprite="fixtures_railings_01_36", north=false, direction="N", state={health=250,hoppable=true,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=317, x=-4, y=-2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=318, x=-4, y=-1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=319, x=-4, y=0, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=320, x=-4, y=1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=321, x=-3, y=-4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=322, x=-3, y=-3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=323, x=-3, y=-2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=324, x=-3, y=-1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=325, x=-3, y=0, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=326, x=-3, y=1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=327, x=-3, y=2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=328, x=-3, y=3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=329, x=-3, y=4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=330, x=-3, y=5, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=331, x=-3, y=6, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=332, x=-3, y=7, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=333, x=-3, y=8, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=334, x=-3, y=9, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=335, x=-3, y=10, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=336, x=-3, y=11, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=337, x=-3, y=12, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=338, x=-3, y=13, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=339, x=-3, y=14, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=340, x=-2, y=-5, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=341, x=-2, y=-4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=342, x=-2, y=-3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=343, x=-2, y=-2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=344, x=-2, y=-1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=345, x=-2, y=0, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=346, x=-2, y=1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=347, x=-2, y=2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=348, x=-2, y=3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=349, x=-2, y=4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=350, x=-2, y=5, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=351, x=-2, y=6, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=352, x=-2, y=7, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=353, x=-2, y=8, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=354, x=-2, y=9, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=355, x=-2, y=10, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=356, x=-2, y=11, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=357, x=-2, y=12, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=358, x=-2, y=13, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=359, x=-2, y=14, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=150,hoppable=false,locked=false,maxHealth=150}, protectionClass=3},
    {templateIndex=360, x=-2, y=15, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=150,hoppable=false,locked=false,maxHealth=150}, protectionClass=3},
    {templateIndex=361, x=-1, y=-5, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=362, x=-1, y=-4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=363, x=-1, y=-3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=364, x=-1, y=-2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=365, x=-1, y=-1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=366, x=-1, y=0, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=367, x=-1, y=1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=368, x=-1, y=2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=369, x=-1, y=3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=370, x=-1, y=4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=371, x=-1, y=5, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=372, x=-1, y=6, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=373, x=-1, y=7, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=374, x=-1, y=8, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=375, x=-1, y=9, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=376, x=-1, y=10, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=377, x=-1, y=11, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=378, x=-1, y=12, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=379, x=-1, y=13, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=150,hoppable=false,locked=false,maxHealth=150}, protectionClass=3},
    {templateIndex=380, x=-1, y=14, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=150,hoppable=false,locked=false,maxHealth=150}, protectionClass=3},
    {templateIndex=381, x=-1, y=15, z=1, class="IsoObject", name="IsoObject", sprite="location_shop_fossoil_01_39", north="none", direction="N", state={hoppable=false}, protectionClass=3},
    {templateIndex=382, x=0, y=-4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=383, x=0, y=-3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=384, x=0, y=-2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=385, x=0, y=-1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=386, x=0, y=0, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=387, x=0, y=1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=388, x=0, y=2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=389, x=0, y=3, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=390, x=0, y=4, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=391, x=0, y=5, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=392, x=0, y=6, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=393, x=0, y=7, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=394, x=0, y=8, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=395, x=0, y=9, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=396, x=0, y=10, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=397, x=0, y=11, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=398, x=0, y=12, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=399, x=0, y=13, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=150,hoppable=false,locked=false,maxHealth=150}, protectionClass=3},
    {templateIndex=400, x=0, y=14, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=150,hoppable=false,locked=false,maxHealth=150}, protectionClass=3},
    {templateIndex=401, x=1, y=-2, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=402, x=1, y=-1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=403, x=1, y=0, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=404, x=1, y=1, z=1, class="IsoThumpable", name="Thumpable", sprite="location_shop_fossoil_01_39", north=false, direction="N", state={health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=405, x=-5, y=-1, z=0, class="IsoThumpable", name="Dark Fancy Wardrobe", sprite="furniture_storage_01_24", north=true, direction="N", state={doRender=false,health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=406, x=-5, y=-2, z=0, class="IsoThumpable", name="Dark Fancy Wardrobe", sprite="furniture_storage_01_25", north=true, direction="N", state={doRender=false,health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=407, x=-5, y=1, z=0, class="IsoThumpable", name="Dark Fancy Wardrobe", sprite="furniture_storage_01_24", north=true, direction="N", state={doRender=false,health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=408, x=-5, y=0, z=0, class="IsoThumpable", name="Dark Fancy Wardrobe", sprite="furniture_storage_01_25", north=true, direction="N", state={doRender=false,health=200,hoppable=false,locked=false,maxHealth=200}, protectionClass=3},
    {templateIndex=409, x=-4, y=16, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=410, x=2, y=-6, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=411, x=2, y=16, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
    {templateIndex=412, x=2, y=17, z=0, class="IsoThumpable", name="Wooden Wall", sprite="walls_interior_house_02_32", north=false, direction="N", state={doRender=false,health=250,hoppable=false,locked=false,maxHealth=250}, protectionClass=3},
}

local function sameState(actual, expected)
    if type(actual) ~= "table" or type(expected) ~= "table" then return false end
    local actualCount, expectedCount = 0, 0
    for key, value in pairs(actual) do
        actualCount = actualCount + 1
        if expected[key] ~= value then return false end
    end
    for key in pairs(expected) do expectedCount = expectedCount + 1 end
    return actualCount == expectedCount
end

local function northValue(record)
    if record.north == "none" then return nil end
    return record.north
end

local templateObjectKeys = {
    x = true, y = true, z = true, class = true, name = true,
    sprite = true, north = true, direction = true, state = true,
}

local function sameIdentity(record, captured)
    if type(captured) ~= "table" then return false end
    for key in pairs(captured) do
        if not templateObjectKeys[key] then return false end
    end
    return type(captured) == "table"
        and captured.x == record.x and captured.y == record.y and captured.z == record.z
        and captured.class == record.class and captured.name == record.name
        and captured.sprite == record.sprite and captured.direction == record.direction
        and captured.north == northValue(record)
        and sameState(captured.state, record.state)
end

function P.validateTemplate(template)
    if type(template) ~= "table" or template.schemaVersion ~= 10
        or template.objectCount ~= P.OBJECT_COUNT or type(template.objects) ~= "table"
        or #template.objects ~= P.OBJECT_COUNT then
        return false, "captured object list does not use the current protection schema"
    end
    local manifestKeys, templateKeys = 0, 0
    local counts = { [1] = 0, [2] = 0, [3] = 0, [4] = 0 }
    for key in pairs(P.objects) do
        manifestKeys = manifestKeys + 1
        if type(key) ~= "number" or math.floor(key) ~= key or key < 1 or key > P.OBJECT_COUNT then
            return false, "static protection ledger index is invalid"
        end
    end
    if manifestKeys ~= P.OBJECT_COUNT then return false, "static protection ledger is incomplete" end
    for key in pairs(template.objects) do
        templateKeys = templateKeys + 1
        if type(key) ~= "number" or math.floor(key) ~= key
            or key < 1 or key > P.OBJECT_COUNT then
            return false, "captured object index is invalid"
        end
    end
    if templateKeys ~= P.OBJECT_COUNT then
        return false, "captured object list is not a dense current-schema list"
    end
    for index = 1, P.OBJECT_COUNT do
        local record, captured = P.objects[index], template.objects[index]
        if type(record) ~= "table" or record.templateIndex ~= index
            or not counts[record.protectionClass] or not sameIdentity(record, captured) then
            return false, "static protection ledger identity mismatch at " .. tostring(index)
        end
        counts[record.protectionClass] = counts[record.protectionClass] + 1
    end
    for class = 1, 4 do
        if counts[class] ~= P.EXPECTED_CLASS_COUNTS[class] then
            return false, "static protection class count mismatch for " .. tostring(class)
        end
    end
    return true
end

function P.get(templateIndex)
    if type(templateIndex) ~= "number" or math.floor(templateIndex) ~= templateIndex then return nil end
    return P.objects[templateIndex]
end

function P.matchesLayoutEntry(index, entry, anchor)
    local record = P.get(index)
    if not record or type(entry) ~= "table" or type(anchor) ~= "table" then return false end
    return entry.templateIndex == index and entry.protectionClass == record.protectionClass
        and entry.x == anchor.x + record.x and entry.y == anchor.y + record.y
        and entry.z == anchor.z + record.z and entry.class == record.class
        and entry.name == record.name and entry.sprite == record.sprite
        and entry.direction == record.direction and entry.north == northValue(record)
        and sameState(entry.state, record.state)
end

function P.matchesCapturedEntry(index, entry)
    local record = P.get(index)
    if not record or type(entry) ~= "table" then return false end
    return entry.templateIndex == index
        and entry.protectionClass == record.protectionClass
        and entry.class == record.class and entry.name == record.name
        and entry.sprite == record.sprite
        and entry.direction == record.direction
        and entry.north == northValue(record)
        and sameState(entry.state, record.state)
end

function P.worldEntry(templateIndex, anchor)
    local record = P.get(templateIndex)
    if not record or type(anchor) ~= "table"
        or type(anchor.x) ~= "number" or type(anchor.y) ~= "number"
        or type(anchor.z) ~= "number" then
        return nil
    end
    return {
        templateIndex = record.templateIndex,
        x = anchor.x + record.x,
        y = anchor.y + record.y,
        z = anchor.z + record.z,
        class = record.class,
        name = record.name,
        sprite = record.sprite,
        north = northValue(record),
        direction = record.direction,
        state = record.state,
        protectionClass = record.protectionClass,
    }
end

return P
