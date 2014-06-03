require 'spec_helper'
require_relative 'shared_examples'

describe Riak::Crdt::Map do
  let(:bucket) do
    double('bucket').tap do |b|
      b.stub(:name).and_return('bucket')
      b.stub(:is_a?).and_return(true)
      b.stub(:client).and_return(client)
    end
  end
  let(:operator){ double 'operator' }
  let(:loader){ double 'loader' }
  let(:backend){ double 'backend' }
  let(:client){ double 'client' }
  let(:key){ 'map' }
  
  before(:each) do
    client.stub(:backend).and_yield(backend)
    backend.stub(:crdt_operator).and_return(operator)
    backend.stub(:crdt_loader).and_return(loader)
    loader.stub(:load).and_return({})
    loader.stub(:context).and_return('context')
  end
  
  subject{ described_class.new bucket, key }
  
  include_examples 'Map CRDT'

  describe 'batch mode' do
    it 'should queue up operations' do
      operator.
        should_receive(:operate) do |bucket, key_arg, type, operations|

        expect(bucket).to eq bucket
        expect(key_arg).to eq key
        expect(type).to eq subject.bucket_type

        expect(operations.length).to eq 2
        
        expect(operations.first).to be_a Riak::Crdt::Operation::Update

        expect(operations.first.value).to be_a Riak::Crdt::Operation::Update
      end

      subject.batch do |s|
        s.registers['hello'] = 'hello'
        s.maps['goodbye'].flags['okay'] = true
      end
    end
  end

  describe 'immediate mode' do
    it 'should submit member operations immediately' do
      operator.
        should_receive(:operate) do |bucket, key_arg, type, operations|

        expect(bucket).to eq bucket
        expect(key_arg).to eq key
        expect(type).to eq subject.bucket_type

        expect(operations.length).to eq 1

        expect(operations.first).to be_a Riak::Crdt::Operation::Update

        inner_op = operations.first.value

        expect(inner_op).to be_a Riak::Crdt::Operation::Update
        expect(inner_op.name).to eq 'hasta'
        expect(inner_op.type).to eq :register
        expect(inner_op.value).to eq 'la vista'
      end

      subject.registers['hasta'] = 'la vista' # baby
    end
  end
end