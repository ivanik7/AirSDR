#pragma once

#include <csdr/module.hpp>
#include <initializer_list>
#include <vector>

namespace Digiham {

    namespace RrcFilter {

        class RrcFilter: public Csdr::AnyLengthModule<float, float> {
            public:
                RrcFilter(unsigned int nZeros, double gain, const float coeffs[]);
                ~RrcFilter() override;
                void process(float* input, float* output, size_t length) override;
            private:
                float filter(float sample);
                unsigned int nZeros;
                double gain;
                // The upstream constructors pass temporary compound-literal arrays.
                // Own a copy so their lifetime cannot end before the next block.
                std::vector<float> coeffs;
                float* delay;
        };

        class NarrowRrcFilter: public RrcFilter {
            public:
                NarrowRrcFilter();
        };

        class WideRrcFilter: public RrcFilter {
            public:
                WideRrcFilter();
        };

    }

}