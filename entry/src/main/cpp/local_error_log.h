#pragma once
#include <string>
namespace LocalErrorLog {
void Configure(const std::string& directory) noexcept;
void Append(const std::string& level, const std::string& component,
            const std::string& message, const std::string& stack = "") noexcept;
std::string Redact(const std::string& text);
}
