cmake_minimum_required(VERSION 3.10)
project(softether_jni)

add_library(softether_jni SHARED softether_jni.cpp)

find_library(log-lib log)

target_link_libraries(softether_jni ${log-lib})

# Enable C++11 standard
set_target_properties(softether_jni PROPERTIES
    CXX_STANDARD 11
    CXX_STANDARD_REQUIRED ON
)
