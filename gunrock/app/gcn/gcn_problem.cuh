// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * graphsum_problem.cuh
 *
 * @brief GPU Storage management Structure for SSSP Problem Data
 */

#pragma once

#include <gunrock/app/problem_base.cuh>
#include <gunrock/app/gcn/sparseMatMul/sparseMatMul_app.cu>
#include <gunrock/app/gcn/graphsum/graphsum_app.cu>
#include <gunrock/app/gcn/CrossEntropyLoss/CrossEntropyLoss_app.cu>
#include <gunrock/app/gcn/dropout/dropout.cuh>
#include <gunrock/app/gcn/matmul/mat_mul.cuh>
#include <gunrock/app/gcn/relu/relu.cuh>
#include "rapidjson/document.h"

namespace gunrock {
namespace app {
namespace gcn {
/**
 * @brief Speciflying parameters for graphsum Problem
 * @param  parameters  The util::Parameter<...> structure holding all parameter
 * info \return cudaError_t error message(s), if any
 */
cudaError_t UseParameters_problem(util::Parameters &parameters) {
  cudaError_t retval = cudaSuccess;

  GUARD_CU(gunrock::app::UseParameters_problem(parameters));
  GUARD_CU(parameters.Use<int>("in_dim",
      util::OPTIONAL_ARGUMENT | util::SINGLE_VALUE | util::OPTIONAL_PARAMETER,
      0, "input_dimension", __FILE__, __LINE__))

  GUARD_CU(parameters.Use<int>("out_dim",
      util::OPTIONAL_ARGUMENT | util::SINGLE_VALUE | util::OPTIONAL_PARAMETER,
      0, "input_dimension", __FILE__, __LINE__))

  GUARD_CU(parameters.Use<int>("hid_dim",
      util::OPTIONAL_ARGUMENT | util::SINGLE_VALUE | util::OPTIONAL_PARAMETER,
      16, "input_dimension", __FILE__, __LINE__))

  GUARD_CU(parameters.Use<double>("learning_rate",
      util::OPTIONAL_ARGUMENT | util::SINGLE_VALUE | util::OPTIONAL_PARAMETER,
      0.005, "learning rate", __FILE__, __LINE__))

  return retval;
}

/**
 * @brief Single-Source Shortest Path Problem structure.
 * @tparam _GraphT  Type of the graph
 * @tparam _LabelT  Type of labels used in sssp
 * @tparam _ValueT  Type of per-vertex distance values
 * @tparam _FLAG    Problem flags
 */
template <typename _GraphT, typename _LabelT = typename _GraphT::VertexT,
          typename _ValueT = typename _GraphT::ValueT,
          ProblemFlag _FLAG = Problem_None>
struct Problem : ProblemBase<_GraphT, _FLAG> {
  typedef _GraphT GraphT;
  static const ProblemFlag FLAG = _FLAG;
  typedef typename GraphT::VertexT VertexT;
  typedef typename GraphT::SizeT SizeT;
  typedef typename GraphT::CsrT CsrT;
  typedef typename GraphT::GpT GpT;
  typedef _LabelT LabelT;
  typedef _ValueT ValueT;

  typedef ProblemBase<GraphT, FLAG> BaseProblem;
  typedef DataSliceBase<GraphT, FLAG> BaseDataSlice;
  typedef util::Parameters Parameters;

  typedef util::Array1D<SizeT, ValueT> Array;
  typedef typename app::TestGraph<VertexT, SizeT, ValueT, graph::HAS_CSR | graph::HAS_EDGE_VALUES>
      SpmatT;

  enum layerType { DROPOUT, SPR_MUL, GRAPH_SUM, RELU, MAT_MUL, CROSS_ENTROPY };
  struct layerParam {
    Array* output, output_grad;
    enum layerType type;
    int dim;
    Array* w, w_grad;
    bool decay;
    layerParam(int dim) : dim(dim) {}
  };

  // Helper structures

  struct adam_var {
    Array weights, grads, m, v;
    bool decay;
    adam_var(Array &_w, Array &_g, bool _d) : decay(_d), weights(_w), grads(_g) {
      init();
    }
    cudaError_t init() {
      auto retval = cudaSuccess;
      GUARD_CU (m.Allocate (weights.GetSize (), util::DEVICE))
      GUARD_CU (m.ForEach ([]__host__ __device__(ValueT &x) { x = 0; }))
      GUARD_CU (v.Allocate (weights.GetSize (), util::DEVICE))
      GUARD_CU(v.ForEach ([]__host__ __device__(ValueT &x) { x = 0; }))
      return retval;
    }
  };

  /**
   * @brief Data structure containing graphsum-specific data on indivual GPU.
   */
  struct DataSlice : BaseDataSlice {
    typedef util::Array1D<SizeT, ValueT> Array;

    double learning_rate = 0.01, beta1 = 0.9, beta2 = 0.999, eps = 1e-8, weight_decay = 5e-4;

    std::vector<module*> modules;
    std::vector<adam_var> vars;
    util::Array1D<SizeT, int> truth, wrong, cnt, label, split;
    Array penalty, in_feature, x_val;
    SpmatT x_work;
    const char* json = " {\n  \"type\":\"custome\",\n  \"layers\":[\n    {\n      \"name\":\"input\"\n    },\n    {\n      \"name\":\"dropout\",\n      \"rate\":0.5\n    },\n    {\n      \"name\":\"sprmul\",\n      \"height\":\"num_nodes\",\n      \"width\":16,\n      \"decay\":\"true\"\n    },\n    {\n      \"name\":\"graph_sum\"\n    },\n    {\n      \"name\":\"relu\"\n    },\n    {\n      \"name\":\"dropout\",\n      \"rate\":0.5\n    },\n    {\n      \"name\":\"mat_mul\",\n      \"height\":16,\n      \"width\":\"out_dim\",\n      \"decay\":\"false\"\n    },\n    {\n      \"name\":\"graph_sum\"\n    },\n    {\n      \"name\":\"cross_entropy\"\n    }\n  ]\n}\n";
    enum layerType layers[8] {DROPOUT, SPR_MUL, GRAPH_SUM, RELU, DROPOUT, MAT_MUL, GRAPH_SUM, CROSS_ENTROPY};
    // w pointer arrays for each layer, will not be initialised if layer does not have it
    Array* w_arr[8];
    Array* w_grad_arr[8];
    Array* inputs[9];
    Array* inputs_grad[9];
    std::string inputs_name[9];
    std::vector<Array*> w;
    std::vector<Array*> w_grad;
    std::vector<layerParam> layerParams;
    Array out;
    curandGenerator_t gen;
    util::GpuTimer timer;
    float tot_time = 0, fw_dropout = 0, fw_sprmul = 0, fw_matmul = 0, fw_graphsum = 0, fw_relu = 0, fw_loss = 0;
    float bw_dropout = 0, bw_sprmul = 0, bw_matmul = 0, bw_graphsum = 0, bw_relu = 0;

    int in_dim, hid_dim, out_dim, num_nodes, max_iter;
    bool training;
    /*
     * @brief Default constructor
     */
    DataSlice() : BaseDataSlice() {
//      loss.SetName ("loss");
      split.SetName ("split");
      in_feature.SetName ("in_feature");
      label.SetName ("label");
      penalty.SetName ("penalty");
      wrong.SetName ("wrong");
      cnt.SetName ("cnt");
      truth.SetName ("truth");
      penalty.SetName("penalty");
    }

    /*
     * @brief Default destructor
     */
    virtual ~DataSlice() { Release(); }

    /*
     * @brief Releasing allocated memory space
     * @param[in] target      The location to release memory from
     * \return    cudaError_t Error message(s), if any
     */
    cudaError_t Release(util::Location target = util::LOCATION_ALL) {
      cudaError_t retval = cudaSuccess;
      if (target & util::DEVICE) GUARD_CU(util::SetDevice(this->gpu_idx));

      GUARD_CU(BaseDataSlice ::Release(target));
      return retval;
    }

    /**
     * @brief initializing graphsum-specific data on each gpu
     * @param     sub_graph   Sub graph on the GPU.
     * @param[in] num_gpus    Number of GPUs
     * @param[in] gpu_idx     GPU device index
     * @param[in] target      Targeting device location
     * @param[in] flag        Problem flag containling options
     * \return    cudaError_t Error message(s), if any
     */
    cudaError_t Init(GraphT &sub_graph, util::Parameters &parameters, SpmatT &x, int *_truth,
                     int num_gpus = 1, int gpu_idx = 0,
                     util::Location target = util::DEVICE,
                     ProblemFlag flag = Problem_None) {
      cudaError_t retval = cudaSuccess;
      this->in_dim = parameters.Get<int>("in_dim");
      this->hid_dim = parameters.Get<int>("hid_dim");
      this->out_dim = parameters.Get<int>("out_dim");
      this->max_iter = parameters.Get<int>("max_iter");
      this->training = parameters.Get<bool>("training");
      this->learning_rate = parameters.Get<double>("learning_rate");
      this->num_nodes = sub_graph.nodes;
//      this->x_ptr = &x;

      GUARD_CU(BaseDataSlice::Init(sub_graph, num_gpus, gpu_idx, target, flag));

      GUARD_CU (in_feature.Allocate (x.edges))
      GUARD_CU (penalty.Allocate (1))
      GUARD_CU (wrong.Allocate (1))
      GUARD_CU (cnt.Allocate (1))
      GUARD_CU (label.Allocate (num_nodes))
      GUARD_CU (truth.Allocate (num_nodes))
      GUARD_CU (split.Allocate (num_nodes))
      GUARD_CU (cnt.Allocate (1))

      GUARD_CU (label.SetPointer(_truth, num_nodes, util::HOST))
      GUARD_CU (label.Move(util::HOST, util::DEVICE))
//      GUARD_CU (truth.Print ())

      rapidjson::Document d;
      d.Parse(json);
      int curDim = in_dim;
      for (auto &v : d["layers"].GetArray()) {
        if (v.HasMember("width")) {
          auto &width = v["width"];
          if (width.IsInt()) {
            curDim = width.GetInt();
          } else {
            // TODO: strcmp with out_dim
            curDim = out_dim;
          }
        }
        layerParams.push_back(layerParam(curDim));
      }

      for (layerParam p : layerParams) {
        printf("%d\n", p.dim);
      }

      x_work = x;
      GUARD_CU(x_work.Move(util::HOST, target, this->stream));
      Array *input = &x_work.edge_values;
      Array *input_grad = nullptr;
      inputs[0] = input;
      inputs_grad[0] = input_grad;

      for (int i = 1; i < 9; i++) {
        // The input to the current i is the output from the previous i
        // If previous i is transformative a new Array is needed
        enum layerType layer = layers[i-1];
        if (layer == SPR_MUL || layer == GRAPH_SUM || layer == MAT_MUL) {
          input = new Array;
          input_grad = new Array;
          GUARD_CU(input->Allocate(num_nodes * layerParams[i].dim))
          GUARD_CU(input_grad->Allocate(num_nodes * layerParams[i].dim))
        }
        inputs[i] = input;
        inputs_grad[i] = input_grad;
      }
      // Replace out with contents of last input, then make last input point to it
      out = *inputs[8];
      inputs[8] = &out;

      std::string array_name = "x";
      inputs_name[0] = array_name;
      curandCreateGenerator (&gen, CURAND_RNG_PSEUDO_XORWOW);
      for (int i = 0; i < 8; i++) {
        enum layerType layer = layers[i];
        if (layer == SPR_MUL || layer == MAT_MUL) {
          Array *w_curr = new Array;
          Array *w_grad_curr = new Array;

          std::string num = std::to_string(w.size());
          w_curr->SetName("w" + num);
          w_grad_curr->SetName("w" + num + "_grad");
          GUARD_CU(w_curr->Allocate(layerParams[i].dim * layerParams[i+1].dim))
          GUARD_CU(w_grad_curr->Allocate(layerParams[i].dim * layerParams[i+1].dim))
          curandGenerateUniformDouble(gen, w_curr->GetPointer(util::DEVICE), w_curr->GetSize());

          ValueT range = sqrt(6.0 / (layerParams[i].dim + layerParams[i+1].dim));
          GUARD_CU(w_curr->ForEach([range] __host__ __device__(ValueT &x) {
            x = (x - 0.5) * range * 2;
          }))

          w_arr[i] = w_curr;
          w_grad_arr[i] = w_grad_curr;
          w.push_back(w_curr);
          w_grad.push_back(w_grad_curr);
        }

        switch (layer) {
          case DROPOUT:
          case RELU:
          case CROSS_ENTROPY:
            break;
          case SPR_MUL:
          case MAT_MUL:
            array_name += "w" + std::to_string(w.size() - 1);
            break;
          case GRAPH_SUM:
            array_name = "A" + array_name;
            break;
        }
        inputs_name[i + 1] = array_name;

        if (inputs[i + 1] != inputs[0]) {
          inputs[i + 1]->SetName(array_name);
          inputs_grad[i + 1]->SetName(array_name + "_grad");
        }
      }

      for (std::string name : inputs_name) {
        std::cout << name << std::endl;
      }

      for (int i = 0; i < 8; i++) {
        module *m;
        switch (layers[i]) {
          case DROPOUT: m = new dropout<SizeT, ValueT>(*inputs[i], inputs_grad[i], 0.5, &gen, &fw_dropout, &bw_dropout); break;
          case SPR_MUL: m = new sprmul<SizeT, ValueT, SpmatT>(parameters, x_work, *w_arr[i], *w_grad_arr[i], *inputs[i+1], *inputs_grad[i+1], layerParams[i].dim, layerParams[i+1].dim, &fw_sprmul, &bw_sprmul); break;
          case GRAPH_SUM: m = new graph_sum<SizeT, ValueT, GraphT>(parameters, sub_graph, *inputs[i], *inputs_grad[i], *inputs[i+1], *inputs_grad[i+1], layerParams[i].dim, &fw_graphsum, &bw_graphsum); break;
          case RELU: m = new relu<SizeT, ValueT>(*inputs[i], *inputs_grad[i], num_nodes * layerParams[i].dim, &fw_relu, &bw_relu); break;
          case MAT_MUL: m = new mat_mul<SizeT, ValueT>(*inputs[i], *inputs_grad[i], *w_arr[i], *w_grad_arr[i], *inputs[i+1], *inputs_grad[i+1], num_nodes, layerParams[i].dim, layerParams[i+1].dim, &fw_matmul, &bw_matmul); break;
          case CROSS_ENTROPY: m = new cross_entropy<SizeT, ValueT, GraphT>(parameters, *inputs[i], *inputs_grad[i], truth, num_nodes, layerParams[i].dim, &fw_loss); break;
          default: m = nullptr; break;
        }
        modules.push_back(m);
      }

      x_val = x_work.edge_values;

      GUARD_CU(x_work.edge_values.ForEach(in_feature,
          []__host__ __device__(ValueT &src, ValueT &dst) {
        dst = src;
      }, x.edge_values.GetSize(), util::DEVICE))

      for (int i = 0; i < w.size(); i++) {
        vars.emplace_back(*w[i], *w_grad[i], i == 0 /* TODO: to be read from json */);
      }

      GUARD_CU(sub_graph.Move(util::HOST, target, this->stream));
      return retval;
    }  // Init

    /**
     * @brief Reset problem function. Must be called prior to each run.
     * @param[in] target      Targeting device location
     * \return    cudaError_t Error message(s), if any
     */
    cudaError_t Reset(util::Location target = util::DEVICE) {
      cudaError_t retval = cudaSuccess;
      return retval;
    }
  };  // DataSlice

  // Members
  // Set of data slices (one for each GPU)
  util::Array1D<SizeT, DataSlice> *data_slices;
  SpmatT in;
  int *_truth;

  // Methods

  /**
   * @brief graphsum default constructor
   */
  Problem(util::Parameters &_parameters, ProblemFlag _flag = Problem_None)
      : BaseProblem(_parameters, _flag), data_slices(NULL) {}

  /**
   * @brief graphsum default destructor
   */
  virtual ~Problem() { Release(); }

  /*
   * @brief Releasing allocated memory space
   * @param[in] target      The location to release memory from
   * \return    cudaError_t Error message(s), if any
   */
  cudaError_t Release(util::Location target = util::LOCATION_ALL) {
    cudaError_t retval = cudaSuccess;
    if (data_slices == NULL) return retval;
    for (int i = 0; i < this->num_gpus; i++)
      GUARD_CU(data_slices[i].Release(target));

    if ((target & util::HOST) != 0 &&
        data_slices[0].GetPointer(util::DEVICE) == NULL) {
      delete[] data_slices;
      data_slices = NULL;
    }
    GUARD_CU(BaseProblem::Release(target));
    return retval;
  }

  /**
   * \addtogroup PublicInterface
   * @{
   */


  cudaError_t Extract(ValueT *_w0, ValueT *_w1,
                      util::Location target = util::DEVICE) {
    cudaError_t retval = cudaSuccess;
    SizeT nodes = this->org_graph->nodes;

    if (this->num_gpus == 1) {
      auto &data_slice = data_slices[0][0];

      // Set device
      if (target == util::DEVICE) {
        GUARD_CU(util::SetDevice(this->gpu_idx[0]));
        GUARD_CU (data_slice.w_arr[1]->SetPointer(_w0, data_slice.in_dim * data_slice.hid_dim))
        GUARD_CU (data_slice.w_arr[1]->Move(util::DEVICE, util::HOST))
        GUARD_CU (data_slice.w_arr[5]->SetPointer(_w1, data_slice.out_dim * data_slice.hid_dim))
        GUARD_CU (data_slice.w_arr[5]->Move(util::DEVICE, util::HOST))
      }
    }

    return retval;
  }

  cudaError_t read_feature(Parameters &p, SpmatT &g, int *&truth) {
    typedef typename SpmatT::CsrT CsrT;

    auto retval = cudaSuccess;

    int n_rows = 0, nnz = 0, dim;
    static std::vector<typename GraphT::SizeT> indptr, indices;
    static std::vector<int> labels;
    static std::vector<ValueT> feature_val;
    indptr.push_back(0);
    std::ifstream svmlight_file(p.Get<std::string>("feature_file"));

    int max_idx = 0, max_label = 0;
    while(true) {
        std::string line;
        getline(svmlight_file, line);
        if (svmlight_file.eof()) break;
        indptr.push_back(indptr.back());
        std::istringstream ss(line);

        int label = -1;
        ss >> label;
        labels.push_back(label);
        if (ss.fail()) continue;
        max_label = std::max(max_label, label);

        while (true) {
            std::string kv;
            ss >> kv;
            if(ss.fail()) break;
            std::istringstream kv_ss(kv);

            int k;
            float v;
            char col;
            kv_ss >> k >> col >> v;

            feature_val.push_back(v);
            indices.push_back(k);
            indptr.back() += 1;
            max_idx = std::max(max_idx, k);
          }
      }
    n_rows = indptr.size() - 1;
    nnz = indices.size();
    dim = max_idx + 1;

    p.Set("in_dim", dim);
    p.Set("out_dim", max_label + 1);

    g.CsrT::Allocate(n_rows, nnz, gunrock::util::HOST);
    g.CsrT::row_offsets.SetPointer(indptr.data(), n_rows + 1, gunrock::util::HOST);
    g.CsrT::column_indices.SetPointer(indices.data(), nnz, gunrock::util::HOST);
    g.CsrT::edge_values.SetPointer(feature_val.data(), nnz, gunrock::util::HOST);
    g.nodes = n_rows;
//    std::cout << "n_rows: " << n_rows << '\n';
    g.edges = nnz;
    gunrock::graphio::LoadGraph(p, g);
//    g.Move(util::HOST, util::DEVICE);

//    for (auto e : labels) std::cout << e << '\n'; std::cout << '\n';
    truth = labels.data();

    return retval;
  }

  void get_split(Parameters &p, std::vector<int> &split) {
    std::ifstream split_file(p.Get<std::string>("split_file"));

    while (true) {
      std::string line;
      getline(split_file, line);
      if (split_file.eof()) break;
      int cur_split = stoi(line);
      split.push_back(cur_split);
    }
  }

  /**
   * @brief      initialization function.
   *
   * @param      graph   The graph that SSSP processes on
   * @param[in]  dim     The dimension of the feature vector
   * @param[in]  target  The target
   * @param[in]  Location  Memory location to work on
   *
   * @return     cudaError_t Error message(s), if any
   */
  cudaError_t Init(GraphT &graph, util::Location target = util::DEVICE) {
    cudaError_t retval = cudaSuccess;
    GUARD_CU(BaseProblem::Init(graph, target));
    data_slices = new util::Array1D<SizeT, DataSlice>[this->num_gpus];

    for (int gpu = 0; gpu < this->num_gpus; gpu++) {
      data_slices[gpu].SetName("data_slices[" + std::to_string(gpu) + "]");
      if (target & util::DEVICE) GUARD_CU(util::SetDevice(this->gpu_idx[gpu]));

      GUARD_CU(data_slices[gpu].Allocate(1, target | util::HOST));

      auto &data_slice = data_slices[gpu][0];

      read_feature (BaseProblem::parameters, in, _truth);
//      for (int i = 0; i < graph.nodes; i++) std::cout << _truth[i] << '\n';
//      std::cout << '\n';
      std::vector<int> split;
      get_split(BaseProblem::parameters, split);
      data_slice.Init(this->sub_graphs[gpu], BaseProblem::parameters, in, _truth, this->num_gpus,
                               this->gpu_idx[gpu], target, this->flag);
      GUARD_CU (data_slice.split.SetPointer(split.data (), graph.nodes, util::HOST))
      GUARD_CU (data_slice.split.Move(util::HOST, util::DEVICE))
    }  // end for (gpu)

    return retval;
  }

  /**
   * @brief Reset problem function. Must be called prior to each run.
   * @param[in] location Memory location to work on
   * \return cudaError_t Error message(s), if any
   */
  cudaError_t Reset(util::Location target = util::DEVICE) {
    cudaError_t retval = cudaSuccess;

    for (int gpu = 0; gpu < this->num_gpus; ++gpu) {
      // Set device
      if (target & util::DEVICE) GUARD_CU(util::SetDevice(this->gpu_idx[gpu]));
      GUARD_CU(data_slices[gpu]->Reset(target));
      GUARD_CU(data_slices[gpu].Move(util::HOST, target));
    }

    if (target & util::DEVICE) {
      GUARD_CU2(cudaDeviceSynchronize(), "cudaDeviceSynchronize failed");
    }

    return retval;
  }

  /** @} */
};

}  // namespace graphsum
}  // namespace app
}  // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
