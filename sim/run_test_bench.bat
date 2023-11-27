echo off
setlocal enabledelayedexpansion

set test_bench_files=run_test_frame_buffer_init16^
 run_test_frame_buffer_init0^
 run_test_frame_buffer_init_var_len^
 run_test_frame_buffer_init_rnd_len^
 run_test_frame_buffer_init16_var_len^
 run_test_frame_buffer_init16_rnd_len^
 run_test_frame_buffer_init16_0^
 run_test_frame_buffer_full_frame_23x17^
 run_test_frame_buffer_full_frame_multi_23x17

set output_dir="output"
set tests_path=%cd%

echo|set /p="--------------------------" & echo.
echo|set /p="|     Run testbench      |" & echo.
echo|set /p="--------------------------" & echo.

set len=0 

for %%x in (%test_bench_files%) do (
    set /a len+=1
)

echo Found %len% tests
echo.

set passed_tests=0
set failed_tests=0

for %%x in (%test_bench_files%) do (
    set test_output_path=%output_dir%\%%x
    set test_bat_file=%tests_path%\%%x.bat
    if not exist !test_output_path! (
        mkdir !test_output_path!
    )

    echo|set /p="Run %%x ...        "
    pushd !test_output_path!
    call !test_bat_file! > log_output.txt 2>&1
    set task_exit_code=!ERRORLEVEL!

    if !task_exit_code! neq 0 (
        echo FAIL
        set /a failed_tests+=1
    ) else (
        echo OK
        set /a passed_tests+=1
    )
    popd
    echo.
)

echo|set /p="--------------------------" & echo.
echo Passed %passed_tests% tests
echo Failed %failed_tests% tests
echo|set /p="--------------------------" & echo.
